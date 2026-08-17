#!/bin/bash
# survey依頼を外部workerへ送る前に、scopeとclaim境界を機械検証する。
set -u

readonly MAX_CLAIMS="4"
readonly MAX_PURPOSE_CHARACTERS="500"
readonly MAX_SUBJECT_CHARACTERS="160"
readonly MAX_QUESTION_CHARACTERS="240"
readonly MAX_ANCHORS="4"
readonly MAX_ANCHOR_CHARACTERS="200"
readonly MAX_DONE_WHEN_CHARACTERS="240"
readonly MAX_EXCLUDES="8"
readonly MAX_EXCLUDE_CHARACTERS="160"

fail() {
  printf 'survey-request: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "expected exactly one JSON request argument"
command -v jq >/dev/null 2>&1 || fail "jq is required"

REQUEST_JSON="$1"
printf '%s' "$REQUEST_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || \
  fail "request must be a JSON object"

printf '%s' "$REQUEST_JSON" | jq -e '
  (keys | sort) == ["claims", "purpose"]
  and (.purpose | type == "string" and length > 0)
  and (.claims | type == "array" and length > 0)
' >/dev/null 2>&1 || \
  fail "request must contain only non-empty purpose and claims fields"

PURPOSE_LENGTH=$(printf '%s' "$REQUEST_JSON" | jq -r '.purpose | length') || fail "cannot read purpose"
[ "$PURPOSE_LENGTH" -le "$MAX_PURPOSE_CHARACTERS" ] || \
  fail "purpose exceeds $MAX_PURPOSE_CHARACTERS characters"

CLAIM_COUNT=$(printf '%s' "$REQUEST_JSON" | jq -r '.claims | length') || fail "cannot count claims"
[ "$CLAIM_COUNT" -le "$MAX_CLAIMS" ] || \
  fail "claims exceed $MAX_CLAIMS; split independent boundaries into separate task ids"

printf '%s' "$REQUEST_JSON" | jq -e '
  all(.claims[];
    type == "object"
    and (keys | sort) == ["anchors", "done_when", "exclude", "id", "kind", "question", "subject"]
    and (.id | type == "string")
    and (.kind | type == "string" and IN("behavior", "control_flow", "integration", "contract", "test", "absence"))
    and (.subject | type == "string" and length > 0)
    and (.question | type == "string" and length > 0)
    and (.anchors | type == "array" and length > 0)
    and (.done_when | type == "string" and length > 0)
    and (.exclude | type == "array" and length > 0)
  )
' >/dev/null 2>&1 || \
  fail "each claim requires only id, kind, subject, question, anchors, done_when, and exclude; kind must be behavior, control_flow, integration, contract, test, or absence"

printf '%s' "$REQUEST_JSON" | jq -e '
  [.claims[].id] == [range(1; (.claims | length) + 1) | "C\(.)"]
' >/dev/null 2>&1 || \
  fail "claim ids must be unique and contiguous in C1..C${CLAIM_COUNT} order"

printf '%s' "$REQUEST_JSON" | jq -e \
  --argjson max_subject "$MAX_SUBJECT_CHARACTERS" \
  --argjson max_question "$MAX_QUESTION_CHARACTERS" \
  --argjson max_anchors "$MAX_ANCHORS" \
  --argjson max_anchor "$MAX_ANCHOR_CHARACTERS" \
  --argjson max_done_when "$MAX_DONE_WHEN_CHARACTERS" \
  --argjson max_excludes "$MAX_EXCLUDES" \
  --argjson max_exclude "$MAX_EXCLUDE_CHARACTERS" '
  all(.claims[];
    (.subject | length <= $max_subject)
    and (.question | length <= $max_question)
    and (.anchors | length <= $max_anchors and length == (unique | length))
    and (all(.anchors[]; type == "string" and length > 0 and length <= $max_anchor))
    and (.done_when | length <= $max_done_when)
    and (.exclude | length <= $max_excludes and length == (unique | length))
    and (all(.exclude[]; type == "string" and length > 0 and length <= $max_exclude))
  )
' >/dev/null 2>&1 || \
  fail "claim text or list limits exceeded, or anchors/exclude contain empty or duplicate values"

# key順と空白を正規化し、同じ意味の依頼が同じdigestになるようにする。
printf '%s' "$REQUEST_JSON" | jq -cS . || fail "cannot normalize request"
