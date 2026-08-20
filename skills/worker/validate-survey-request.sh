#!/bin/bash
# survey依頼を外部workerへ送る前に、scopeとclaim境界を機械検証する。
set -u

readonly MAX_CLAIMS="1"
readonly MAX_PURPOSE_CHARACTERS="240"
readonly MAX_SUBJECT_CHARACTERS="120"
readonly MAX_QUESTION_CHARACTERS="160"
readonly MAX_QUESTION_ENUMERATORS="2"
readonly MAX_ANCHORS="4"
readonly MAX_ANCHOR_CHARACTERS="200"
readonly MAX_DONE_WHEN_CHARACTERS="160"
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
    and (.kind | type == "string" and IN("behavior", "control_flow", "integration", "contract", "test", "test_absence"))
    and (.subject | type == "string" and length > 0)
    and (.question | type == "string" and length > 0)
    and (.anchors | type == "array" and length > 0)
    and (.done_when | type == "string" and length > 0)
    and (.exclude | type == "array" and length > 0)
  )
' >/dev/null 2>&1 || \
  fail "each claim requires only id, kind, subject, question, anchors, done_when, and exclude; kind must be behavior, control_flow, integration, contract, test, or test_absence"

printf '%s' "$REQUEST_JSON" | jq -e '
  [.claims[].id] == [range(1; (.claims | length) + 1) | "C\(.)"]
' >/dev/null 2>&1 || \
  fail "claim ids must be unique and contiguous in C1..C${CLAIM_COUNT} order"

CLAIM_INDEX=0
while [ "$CLAIM_INDEX" -lt "$CLAIM_COUNT" ]; do
  CLAIM_ID=$(printf '%s' "$REQUEST_JSON" | jq -r ".claims[$CLAIM_INDEX].id") || fail "cannot read claim id"
  SUBJECT_LENGTH=$(printf '%s' "$REQUEST_JSON" | jq ".claims[$CLAIM_INDEX].subject | length") || fail "cannot read $CLAIM_ID.subject"
  [ "$SUBJECT_LENGTH" -le "$MAX_SUBJECT_CHARACTERS" ] || fail "$CLAIM_ID.subject exceeds $MAX_SUBJECT_CHARACTERS characters (actual $SUBJECT_LENGTH)"

  QUESTION_LENGTH=$(printf '%s' "$REQUEST_JSON" | jq ".claims[$CLAIM_INDEX].question | length") || fail "cannot read $CLAIM_ID.question"
  [ "$QUESTION_LENGTH" -le "$MAX_QUESTION_CHARACTERS" ] || fail "$CLAIM_ID.question exceeds $MAX_QUESTION_CHARACTERS characters (actual $QUESTION_LENGTH)"
  QUESTION_ENUMERATORS=$(printf '%s' "$REQUEST_JSON" | jq "[.claims[$CLAIM_INDEX].question | scan(\"[、,;；]\")] | length") || fail "cannot inspect $CLAIM_ID.question"
  [ "$QUESTION_ENUMERATORS" -le "$MAX_QUESTION_ENUMERATORS" ] || fail "$CLAIM_ID.question has $QUESTION_ENUMERATORS enumerators (maximum $MAX_QUESTION_ENUMERATORS)"

  printf '%s' "$REQUEST_JSON" | jq -e "[.claims[$CLAIM_INDEX].subject, .claims[$CLAIM_INDEX].question, .claims[$CLAIM_INDEX].done_when, .claims[$CLAIM_INDEX].anchors[], .claims[$CLAIM_INDEX].exclude[]] | all(type == \"string\" and length > 0)" >/dev/null 2>&1 || fail "$CLAIM_ID contains a non-string or empty text/list value"
  printf '%s' "$REQUEST_JSON" | jq -e "[.claims[$CLAIM_INDEX].subject, .claims[$CLAIM_INDEX].question, .claims[$CLAIM_INDEX].done_when, .claims[$CLAIM_INDEX].anchors[], .claims[$CLAIM_INDEX].exclude[]] | all(test(\"[\\\\n\\\\r\\\\t]\") | not)" >/dev/null 2>&1 || fail "$CLAIM_ID contains a newline, carriage return, or tab"

  ANCHOR_COUNT=$(printf '%s' "$REQUEST_JSON" | jq ".claims[$CLAIM_INDEX].anchors | length") || fail "cannot count $CLAIM_ID.anchors"
  [ "$ANCHOR_COUNT" -le "$MAX_ANCHORS" ] || fail "$CLAIM_ID.anchors has $ANCHOR_COUNT items (maximum $MAX_ANCHORS)"
  printf '%s' "$REQUEST_JSON" | jq -e ".claims[$CLAIM_INDEX].anchors | length == (unique | length)" >/dev/null 2>&1 || fail "$CLAIM_ID.anchors contains duplicates"
  printf '%s' "$REQUEST_JSON" | jq -e --argjson maximum "$MAX_ANCHOR_CHARACTERS" ".claims[$CLAIM_INDEX].anchors | all(length <= \$maximum)" >/dev/null 2>&1 || fail "$CLAIM_ID.anchors item exceeds $MAX_ANCHOR_CHARACTERS characters"

  DONE_WHEN_LENGTH=$(printf '%s' "$REQUEST_JSON" | jq ".claims[$CLAIM_INDEX].done_when | length") || fail "cannot read $CLAIM_ID.done_when"
  [ "$DONE_WHEN_LENGTH" -le "$MAX_DONE_WHEN_CHARACTERS" ] || fail "$CLAIM_ID.done_when exceeds $MAX_DONE_WHEN_CHARACTERS characters (actual $DONE_WHEN_LENGTH)"

  EXCLUDE_COUNT=$(printf '%s' "$REQUEST_JSON" | jq ".claims[$CLAIM_INDEX].exclude | length") || fail "cannot count $CLAIM_ID.exclude"
  [ "$EXCLUDE_COUNT" -le "$MAX_EXCLUDES" ] || fail "$CLAIM_ID.exclude has $EXCLUDE_COUNT items (maximum $MAX_EXCLUDES)"
  printf '%s' "$REQUEST_JSON" | jq -e ".claims[$CLAIM_INDEX].exclude | length == (unique | length)" >/dev/null 2>&1 || fail "$CLAIM_ID.exclude contains duplicates"
  printf '%s' "$REQUEST_JSON" | jq -e --argjson maximum "$MAX_EXCLUDE_CHARACTERS" ".claims[$CLAIM_INDEX].exclude | all(length <= \$maximum)" >/dev/null 2>&1 || fail "$CLAIM_ID.exclude item exceeds $MAX_EXCLUDE_CHARACTERS characters"
  CLAIM_INDEX=$((CLAIM_INDEX + 1))
done

# key順と空白を正規化し、同じ意味の依頼が同じdigestになるようにする。
printf '%s' "$REQUEST_JSON" | jq -cS . || fail "cannot normalize request"
