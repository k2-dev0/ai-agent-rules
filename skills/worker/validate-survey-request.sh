#!/bin/bash
# survey依頼を正規化し、外部workerへ送る前にscopeとclaim境界を一括検証する。
set -u

readonly MAX_CLAIMS="3"
readonly MAX_PURPOSE_CHARACTERS="240"
readonly MAX_SUBJECT_CHARACTERS="120"
readonly MAX_QUESTION_CHARACTERS="160"
readonly MAX_QUESTION_ENUMERATORS="2"
readonly MAX_ANCHORS="4"
readonly MAX_ANCHOR_CHARACTERS="200"
readonly MAX_DONE_WHEN_CHARACTERS="160"
readonly MAX_EXCLUDES="8"
readonly MAX_EXCLUDE_CHARACTERS="160"

fatal() {
  printf '{"errors":[{"path":"","message":"%s"}],"normalized_request":null}\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fatal "expected exactly one JSON request argument"
command -v jq >/dev/null 2>&1 || fatal "jq is required"

RAW_REQUEST=$1
printf '%s' "$RAW_REQUEST" | jq -e . >/dev/null 2>&1 || fatal "request must be valid JSON"

# 同じ意味のpacketを同じdigestへ寄せる。anchor / excludeは最初の出現順を保持して集合化する。
NORMALIZED_REQUEST=$(printf '%s' "$RAW_REQUEST" | jq -cS '
  def stable_unique:
    reduce .[] as $item ([]; if any(.[]; . == $item) then . else . + [$item] end);
  if type == "object" and (.claims | type) == "array" then
    .claims |= map(
      if type == "object" then
        (if (.anchors | type) == "array" then .anchors |= stable_unique else . end)
        | (if (.exclude | type) == "array" then .exclude |= stable_unique else . end)
      else . end
    )
  else . end
') || fatal "cannot normalize request"

ERRORS='[]'
add_error() {
  ERRORS=$(printf '%s' "$ERRORS" | jq -c --arg path "$1" --arg message "$2" '. + [{path:$path,message:$message}]') || fatal "cannot collect validation errors"
}
json_test() {
  printf '%s' "$NORMALIZED_REQUEST" | jq -e "$1" >/dev/null 2>&1
}

if ! json_test 'type == "object"'; then
  add_error "" "request must be a JSON object"
else
  json_test '(keys | sort) == ["claims", "purpose"]' ||
    add_error "" "request must contain only purpose and claims fields"

  if ! json_test '.purpose | type == "string" and length > 0'; then
    add_error "/purpose" "purpose must be a non-empty string"
  elif ! json_test ".purpose | length <= $MAX_PURPOSE_CHARACTERS"; then
    add_error "/purpose" "purpose exceeds $MAX_PURPOSE_CHARACTERS characters"
  fi

  if ! json_test '.claims | type == "array" and length > 0'; then
    add_error "/claims" "claims must be a non-empty array"
  else
    CLAIM_COUNT=$(printf '%s' "$NORMALIZED_REQUEST" | jq -r '.claims | length') || fatal "cannot count claims"
    [ "$CLAIM_COUNT" -le "$MAX_CLAIMS" ] ||
      add_error "/claims" "claims exceed $MAX_CLAIMS; split source-local packets into separate task ids"

    if json_test 'any(.claims[]; type == "object" and .kind == "test_absence")' && [ "$CLAIM_COUNT" -ne 1 ]; then
      add_error "/claims" "test_absence must be the only claim because the runner verifies it deterministically"
    fi
    json_test '[.claims[].id] == [range(1; (.claims | length) + 1) | "C\(.)"]' ||
      add_error "/claims" "claim ids must be unique and contiguous in C1..${CLAIM_COUNT} order"

    CLAIM_INDEX=0
    while [ "$CLAIM_INDEX" -lt "$CLAIM_COUNT" ]; do
      CLAIM_PATH="/claims/$CLAIM_INDEX"
      CLAIM_ID="C$((CLAIM_INDEX + 1))"
      if ! json_test ".claims[$CLAIM_INDEX] | type == \"object\""; then
        add_error "$CLAIM_PATH" "$CLAIM_ID must be an object"
        CLAIM_INDEX=$((CLAIM_INDEX + 1))
        continue
      fi

      json_test ".claims[$CLAIM_INDEX] | (keys | sort) == [\"anchors\", \"done_when\", \"exclude\", \"id\", \"kind\", \"question\", \"subject\"]" ||
        add_error "$CLAIM_PATH" "$CLAIM_ID requires only id, kind, subject, question, anchors, done_when, and exclude"
      json_test ".claims[$CLAIM_INDEX].kind | type == \"string\" and IN(\"behavior\", \"control_flow\", \"integration\", \"contract\", \"test\", \"test_absence\")" ||
        add_error "$CLAIM_PATH/kind" "$CLAIM_ID.kind is unsupported"

      for FIELD in subject question done_when; do
        if ! json_test ".claims[$CLAIM_INDEX].$FIELD | type == \"string\" and length > 0"; then
          add_error "$CLAIM_PATH/$FIELD" "$CLAIM_ID.$FIELD must be a non-empty string"
        elif ! json_test ".claims[$CLAIM_INDEX].$FIELD | test(\"[\\\\n\\\\r\\\\t]\") | not"; then
          add_error "$CLAIM_PATH/$FIELD" "$CLAIM_ID.$FIELD contains a newline, carriage return, or tab"
        fi
      done

      json_test ".claims[$CLAIM_INDEX].subject | type != \"string\" or length <= $MAX_SUBJECT_CHARACTERS" ||
        add_error "$CLAIM_PATH/subject" "$CLAIM_ID.subject exceeds $MAX_SUBJECT_CHARACTERS characters"
      json_test ".claims[$CLAIM_INDEX].question | type != \"string\" or length <= $MAX_QUESTION_CHARACTERS" ||
        add_error "$CLAIM_PATH/question" "$CLAIM_ID.question exceeds $MAX_QUESTION_CHARACTERS characters"
      json_test ".claims[$CLAIM_INDEX].question | type != \"string\" or ([scan(\"[、,;；]\")] | length) <= $MAX_QUESTION_ENUMERATORS" ||
        add_error "$CLAIM_PATH/question" "$CLAIM_ID.question exceeds $MAX_QUESTION_ENUMERATORS enumerators"
      json_test ".claims[$CLAIM_INDEX].done_when | type != \"string\" or length <= $MAX_DONE_WHEN_CHARACTERS" ||
        add_error "$CLAIM_PATH/done_when" "$CLAIM_ID.done_when exceeds $MAX_DONE_WHEN_CHARACTERS characters"

      if ! json_test ".claims[$CLAIM_INDEX].anchors | type == \"array\" and length > 0 and all(.[]; type == \"string\" and length > 0)"; then
        add_error "$CLAIM_PATH/anchors" "$CLAIM_ID.anchors must be a non-empty string array"
      else
        json_test ".claims[$CLAIM_INDEX].anchors | length <= $MAX_ANCHORS" ||
          add_error "$CLAIM_PATH/anchors" "$CLAIM_ID.anchors exceeds $MAX_ANCHORS items"
        json_test ".claims[$CLAIM_INDEX].anchors | all(length <= $MAX_ANCHOR_CHARACTERS and (test(\"[\\\\n\\\\r\\\\t]\") | not))" ||
          add_error "$CLAIM_PATH/anchors" "$CLAIM_ID.anchors contains an overlong or control-character item"
      fi

      if ! json_test ".claims[$CLAIM_INDEX].exclude | type == \"array\" and length > 0 and all(.[]; type == \"string\" and length > 0)"; then
        add_error "$CLAIM_PATH/exclude" "$CLAIM_ID.exclude must be a non-empty string array"
      else
        json_test ".claims[$CLAIM_INDEX].exclude | length <= $MAX_EXCLUDES" ||
          add_error "$CLAIM_PATH/exclude" "$CLAIM_ID.exclude exceeds $MAX_EXCLUDES items"
        json_test ".claims[$CLAIM_INDEX].exclude | all(length <= $MAX_EXCLUDE_CHARACTERS and (test(\"[\\\\n\\\\r\\\\t]\") | not))" ||
          add_error "$CLAIM_PATH/exclude" "$CLAIM_ID.exclude contains an overlong or control-character item"
      fi
      CLAIM_INDEX=$((CLAIM_INDEX + 1))
    done
  fi
fi

if [ "$(printf '%s' "$ERRORS" | jq 'length')" -gt 0 ]; then
  jq -cn --argjson errors "$ERRORS" --argjson normalized_request "$NORMALIZED_REQUEST" \
    '{errors:$errors,normalized_request:$normalized_request}' >&2
  exit 1
fi

printf '%s\n' "$NORMALIZED_REQUEST"
