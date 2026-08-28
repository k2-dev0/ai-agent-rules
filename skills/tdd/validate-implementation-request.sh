#!/bin/bash
# 親からimplementerへ渡すJSONを検証し、省略・artifact取り違え・scopeずれを起動前に止める。
set -eu

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: validate-implementation-request.sh '<request-json>'"
command -v jq >/dev/null 2>&1 || die "jq が必要"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"

REQUEST=$1
REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"

printf '%s' "$REQUEST" | jq -e '
  type == "object" and
  (keys | sort) == ["action", "allowed_paths", "implementation_instruction", "red", "scope", "spec", "test_exemption", "test_paths", "test_scenarios", "version", "worker_tasks"] and
  .version == 4 and
  .action == "implement" and
  (.scope | type == "string" and test("^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$")) and
  (.implementation_instruction | type == "string" and test("[^[:space:]]")) and
  (.spec == null or (.spec | type == "string" and test("^[^/].*") and (contains("..") | not))) and
  (.worker_tasks | type == "array" and length > 0) and
  (all(.worker_tasks[];
    type == "object" and
    (keys | sort) == ["evidence", "report", "required_claim_ids", "result", "task_id"] and
    (.task_id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")) and
    (.required_claim_ids | type == "array" and length > 0 and
      all(.[]; type == "string" and test("^C[1-9][0-9]*$")) and
      (unique | length) == length) and
    all(.result, .report, .evidence; type == "string" and test("^[^/].*") and (contains("..") | not))
  )) and
  (.allowed_paths | type == "array" and length > 0 and all(.[]; type == "string" and test("^[^/].*") and (contains("..") | not))) and
  (.allowed_paths | unique | length) == (.allowed_paths | length) and
  (
    (.test_exemption == null and
      (.test_paths | type == "array" and length > 0 and all(.[];
        type == "string" and test("^[^/].*") and (contains("..") | not) and
        test("(^|/)(test|tests|__tests__)/|\\.(test|spec)\\.|(^|/)(test_|spec_).+\\.|(_test|_spec)\\.[^/]+$"))) and
      (.test_paths | unique | length) == (.test_paths | length) and
      (.test_scenarios | type == "array" and length > 0 and all(.[];
        type == "object" and
        (keys | sort) == ["contract", "id"] and
        (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (.contract | type == "string" and test("[^[:space:]]")))) and
      (.red | type == "object" and (keys | sort) == ["command", "reason", "status"] and
        (.command | type == "string" and test("[^[:space:]]")) and
        (.status | type == "number" and floor == . and . > 0) and
        (.reason | type == "string" and test("[^[:space:]]"))))
    or
    (.red == null and .test_scenarios == [] and .test_paths == [] and
      (.test_exemption | type == "object" and (keys | sort) == ["paths", "reason"] and
        (.paths | type == "array" and length > 0 and all(.[];
          type == "string" and test("(^|/)schema\\.prisma$|(^|/)constants\\.(ts|js)$|(^|/)constants/"))) and
        (.reason | type == "string" and test("[^[:space:]]"))))
  ) and
  (.test_exemption == null or .test_exemption.paths == .allowed_paths)
' >/dev/null 2>&1 || die "implementation requestのschemaが不正"

SCOPE=$(printf '%s' "$REQUEST" | jq -r '.scope')
SCOPE_RECEIPT="$RECEIPT_DIR/$SCOPE.scope"
[ -f "$SCOPE_RECEIPT" ] || die "polish対象の開始receiptが無い: $SCOPE"
[ ! -e "$RECEIPT_DIR/implementation.active" ] || die "implementation requestはscope activate前に検証すること"
[ "$(sed -n '1p' "$SCOPE_RECEIPT")" = "$REPOSITORY" ] || die "開始receiptのリポジトリが一致しない"

SPEC=$(printf '%s' "$REQUEST" | jq -r '.spec // empty')
if [ -n "$SPEC" ]; then
  case "$SPEC" in .claude/prompt/*|.codex/prompt/*) ;; *) die "specが固定prompt path外にある" ;; esac
  [ -f "$SPEC" ] || die "specが無い: $SPEC"
fi

while IFS= read -r TEST_PATH; do
  [ -f "$TEST_PATH" ] || die "承認済みtestが無い: $TEST_PATH"
  if git ls-files --error-unmatch -- ":(literal)$TEST_PATH" >/dev/null 2>&1; then
    continue
  fi
  git check-ignore -q -- "$TEST_PATH" || \
    die "承認済みtestが追跡済みでもignore対象でもない: $TEST_PATH"
done < <(printf '%s' "$REQUEST" | jq -r '.test_paths[]')

REQUEST_PATHS=$(printf '%s' "$REQUEST" | jq -r '.allowed_paths[]')
RECEIPT_PATHS=$(sed -n '3,$p' "$SCOPE_RECEIPT")
[ "$REQUEST_PATHS" = "$RECEIPT_PATHS" ] || die "allowed_pathsが開始scopeと順序込みで一致しない"

TASK_COUNT=$(printf '%s' "$REQUEST" | jq '.worker_tasks | length')
TASK_INDEX=0
while [ "$TASK_INDEX" -lt "$TASK_COUNT" ]; do
  TASK=$(printf '%s' "$REQUEST" | jq -c ".worker_tasks[$TASK_INDEX]")
  TASK_ID=$(printf '%s' "$TASK" | jq -r '.task_id')
  RESULT_PATH=$(printf '%s' "$TASK" | jq -r '.result')
  REPORT_PATH=$(printf '%s' "$TASK" | jq -r '.report')
  EVIDENCE_PATH=$(printf '%s' "$TASK" | jq -r '.evidence')
  REQUIRED_CLAIM_IDS=$(printf '%s' "$TASK" | jq -r '.required_claim_ids[]')

  case "$RESULT_PATH" in
    ".claude/tmp/worker/$TASK_ID/result.json"|".codex/tmp/worker/$TASK_ID/result.json") ;;
    *) die "worker resultが固定artifact path外にある: $TASK_ID" ;;
  esac
  [ "${RESULT_PATH##*/}" = "result.json" ] || die "worker result pathが不正: $TASK_ID"
  [ "$(basename "$(dirname "$RESULT_PATH")")" = "$TASK_ID" ] || die "worker task-idがdirectoryと一致しない: $TASK_ID"
  [ -f "$RESULT_PATH" ] || die "worker resultが無い: $RESULT_PATH"
  [ -f "$REPORT_PATH" ] || die "worker reportが無い: $REPORT_PATH"
  [ -f "$EVIDENCE_PATH" ] || die "worker evidenceが無い: $EVIDENCE_PATH"
  [ "$(jq -r '.task_id' "$RESULT_PATH")" = "$TASK_ID" ] || die "worker task-idがresultと一致しない: $TASK_ID"
  case "$(jq -r '.mode' "$RESULT_PATH")" in research|survey|nesting) ;; *) die "worker modeが読み取り調査ではない: $TASK_ID" ;; esac
  [ "$(jq -r '.output_contract_status' "$RESULT_PATH")" = "valid" ] || die "worker出力契約が不正: $TASK_ID"
  jq -e '
    (.claim_results | type == "array" and length > 0) and
    ([.claim_results[].id] | length == (unique | length)) and
    all(.claim_results[];
      type == "object" and
      (keys | sort) == ["evidence_count", "evidence_status", "id", "status"] and
      (.id | type == "string" and test("^C[1-9][0-9]*$")) and
      (.status | type == "string" and IN("fulfilled", "partial", "blocked", "unknown")) and
      (.evidence_count | type == "number" and floor == . and . >= 0) and
      (.evidence_status | type == "string" and IN("verified", "missing", "invalid")))
  ' "$RESULT_PATH" >/dev/null 2>&1 || die "worker claim metadataが不正: $TASK_ID"
  [ "$(jq -c '.changed_paths' "$RESULT_PATH")" = "[]" ] || die "workerが変更を生成している: $TASK_ID"
  [ "$(jq -r '.report_file' "$RESULT_PATH")" = "report.md" ] || die "worker report名が不正: $TASK_ID"
  [ "$(jq -r '.evidence_file' "$RESULT_PATH")" = "evidence.md" ] || die "worker evidence名が不正: $TASK_ID"
  [ "$(jq -r '.report_blob' "$RESULT_PATH")" = "$(git hash-object "$REPORT_PATH")" ] || die "worker reportがpublish後に変更されている: $TASK_ID"
  [ "$(jq -r '.evidence_blob' "$RESULT_PATH")" = "$(git hash-object "$EVIDENCE_PATH")" ] || die "worker evidenceがpublish後に変更されている: $TASK_ID"
  [ "$(dirname "$RESULT_PATH")/$(jq -r '.report_file' "$RESULT_PATH")" = "$REPORT_PATH" ] || die "worker report pathがresultと一致しない: $TASK_ID"
  [ "$(dirname "$RESULT_PATH")/$(jq -r '.evidence_file' "$RESULT_PATH")" = "$EVIDENCE_PATH" ] || die "worker evidence pathがresultと一致しない: $TASK_ID"
  [ ! -e "$(dirname "$RESULT_PATH")/candidate.patch" ] || die "worker artifactにcandidate.patchを含められない: $TASK_ID"

  RESULT_STATUS=$(jq -r '.status' "$RESULT_PATH")
  RESULT_OUTCOME=$(jq -r '.outcome' "$RESULT_PATH")
  if [ "$RESULT_STATUS" = "0" ] && [ "$RESULT_OUTCOME" = "fulfilled" ]; then
    [ "$(jq -r '.evidence_status' "$RESULT_PATH")" = "verified" ] || die "worker evidenceが未検証: $TASK_ID"
  else
    case "$RESULT_STATUS:$RESULT_OUTCOME" in
      68:partial|70:partial) ;;
      *) die "worker resultが再利用可能なpartialではない: $TASK_ID" ;;
    esac
  fi
  while IFS= read -r REQUIRED_CLAIM_ID; do
    jq -e --arg id "$REQUIRED_CLAIM_ID" '
      any(.claim_results[];
        .id == $id and
        .status == "fulfilled" and
        .evidence_count > 0 and
        .evidence_status == "verified")
    ' "$RESULT_PATH" >/dev/null 2>&1 ||
      die "required claimが未検証: $TASK_ID $REQUIRED_CLAIM_ID"
  done <<< "$REQUIRED_CLAIM_IDS"
  TASK_INDEX=$((TASK_INDEX + 1))
done

NORMALIZED_REQUEST=$(printf '%s' "$REQUEST" | jq -cS .)
REQUEST_RECEIPT="$RECEIPT_DIR/$SCOPE.implementation-request"
TEMP_RECEIPT="$REQUEST_RECEIPT.tmp.$$"
printf '%s\n' "$NORMALIZED_REQUEST" > "$TEMP_RECEIPT" || die "implementation request receiptを書けない"
mv "$TEMP_RECEIPT" "$REQUEST_RECEIPT" || die "implementation request receiptを確定できない"
printf '%s\n' "$NORMALIZED_REQUEST"
