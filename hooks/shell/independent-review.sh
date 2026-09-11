#!/bin/bash
# 最初のコード編集前のHEADと、起動された専用子の固定入力・最終結果をsession別に保持する。
# 文書への注入receiptやモデルが書いた「完了」印はレビュー証跡にしない。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
EVENT=$(hook_event_name)
TOOL=$(hook_tool_name)
ROOT=$(git -C "$(hook_cwd)" rev-parse --show-toplevel) || exit 0
SESSION=$(hook_session_id)
case "$SESSION" in
  ''|*[!A-Za-z0-9._-]*)
    [ "$EVENT" != PreToolUse ] || hook_deny "独立レビューのsession_idを確定できません。"
    exit 0 ;;
esac
STATE_DIR="$ROOT/.$HOOK_AGENT/tmp"
STATE="$STATE_DIR/independent-review.$SESSION.json"
fail() {
  if [ "$EVENT" = PreToolUse ]; then hook_deny "$1"; fi
  exit 0
}
save() {
  local DATA=$1 TEMP
  mkdir -p "$STATE_DIR" || fail "独立レビュー状態を保存できません。"
  TEMP=$(mktemp "$STATE_DIR/review-write.XXXXXX") || fail "独立レビュー状態を保存できません。"
  printf '%s\n' "$DATA" > "$TEMP" && mv "$TEMP" "$STATE" || fail "独立レビュー状態を保存できません。"
}
clean() { git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet; }
head() { git -C "$ROOT" rev-parse --verify HEAD; }
code_path() {
  case "$1" in
    *.ts|*.tsx|*.js|*.jsx|*.mts|*.cts|*.mjs|*.cjs|*.py|*.sh|*.bash|*.zsh|*.go|*.rs|*.java|*.kt|*.swift|*.c|*.h|*.cpp|*.cs|*.rb|*.php|*.vue|*.svelte|*.sql|*.prisma) return 0 ;;
  esac
  return 1
}
tracked_paths() {
  local file
  while IFS= read -r file; do
    case "$file" in "$ROOT"/*) file=${file#"$ROOT"/} ;; esac
    [ ! -e "$ROOT/$file" ] || git -C "$ROOT" ls-files --error-unmatch -- "$file" >/dev/null || return 1
  done < <(printf '%s' "$DATA" | jq -r '.paths[]?')
}
[ ! -L "$STATE" ] || fail "独立レビュー状態がsymlinkです。"
DATA='{}'
if [ -f "$STATE" ]; then
  DATA=$(cat "$STATE")
  printf '%s' "$DATA" | jq -e 'type == "object" and (.base | type == "string")' >/dev/null || fail "独立レビュー状態が壊れています。"
fi
case "$EVENT" in
  UserPromptSubmit)
    [ -f "$STATE" ] || exit 0
    # 完了したレビューは次の依頼へ持ち越さず、未完了の比較元だけ保持する。
    if printf '%s' "$DATA" | jq -e '.result.status == "reviewed"' >/dev/null && clean && [ "$(head)" = "$(printf '%s' "$DATA" | jq -r '.result.review_head')" ]; then
      rm -f "$STATE"
    else
      save "$(printf '%s' "$DATA" | jq 'del(.result, .pending) | .generation = ((.generation // 0) + 1)')"
    fi
    ;;
  PreToolUse)
    case "$TOOL" in
      Edit|Write|MultiEdit|NotebookEdit|apply_patch)
        PATHS=$(hook_file_paths)
        REQUIRED=false
        while IFS= read -r FILE; do code_path "$FILE" && REQUIRED=true; done <<< "$PATHS"
        [ "$REQUIRED" = true ] || exit 0
        if [ ! -f "$STATE" ]; then
          BASE=$(head) || hook_deny "変更前HEADがありません。初期commitを作成してから編集してください。"
          DATA=$(jq -cn --arg base "$BASE" '{base:$base,generation:0,paths:[]}')
        fi
        save "$(printf '%s' "$DATA" | jq --arg paths "$PATHS" '.paths = (((.paths // []) + ($paths | split("\n"))) | unique) | del(.result, .pending)')"
        ;;
      Agent|*spawn_agent)
        ROLE=$(hook_agent_type)
        case "$ROLE" in code-reviewer|deep-reviewer) ;; *) exit 0 ;; esac
        BRIEF=$(hook_review_brief) || hook_deny "コードレビューはrepository・review_base・review_head・requirementsを持つJSONで起動してください。"
        printf '%s' "$BRIEF" | jq -e 'all(.repository,.review_base,.review_head,.requirements; type == "string" and length > 0)' >/dev/null || hook_deny "独立レビューの入力が不足しています。"
        BASE=$(printf '%s' "$BRIEF" | jq -r '.review_base')
        HEAD=$(printf '%s' "$BRIEF" | jq -r '.review_head')
        printf '%s\n%s\n' "$BASE" "$HEAD" | grep -Ev '^([0-9a-f]{40}|[0-9a-f]{64})$' >/dev/null && hook_deny "review_base・review_headは完全なcommit SHAにしてください。"
        [ "$(printf '%s' "$BRIEF" | jq -r '.repository')" = "$ROOT" ] && [ "$HEAD" = "$(head)" ] && clean || hook_deny "独立レビューのrepository・HEAD・追跡fileのclean状態が一致しません。"
        git -C "$ROOT" merge-base --is-ancestor "$BASE" "$HEAD" || hook_deny "独立レビューの比較元が対象HEADの祖先ではありません。"
        if [ -f "$STATE" ]; then
          [ "$BASE" = "$(printf '%s' "$DATA" | jq -r '.base')" ] || hook_deny "review_baseを変更開始後のcommitへ縮めることはできません。"
        else
          DATA=$(jq -cn --arg base "$BASE" '{base:$base,generation:0,paths:[]}')
        fi
        REQUEST_ID=$(printf '%s' "$BRIEF" | jq -cS . | shasum -a 256 | awk '{print $1}')
        [ "${#REQUEST_ID}" = 64 ] || hook_deny "独立レビュー入力のhashを計算できません。"
        BRIEF=$(printf '%s' "$BRIEF" | jq -c --arg request_id "$REQUEST_ID" '. + {request_id:$request_id}')
        save "$(printf '%s' "$DATA" | jq --argjson brief "$BRIEF" --arg role "$ROLE" --arg request_id "$REQUEST_ID" '.pending = {brief:$brief,role:$role,request_id:$request_id,generation:(.generation // 0)} | del(.result)')"
        UPDATED=$(printf '%s' "$HOOK_INPUT" | jq -c --argjson brief "$BRIEF" '.tool_input | if has("prompt") then .prompt = ($brief | tojson) else .message = ($brief | tojson) end')
        hook_rewrite_input "$UPDATED"
        ;;
    esac
    ;;
  SubagentStart)
    ROLE=$(hook_child_role)
    case "$ROLE" in code-reviewer|deep-reviewer) ;; *) exit 0 ;; esac
    [ "$(printf '%s' "$DATA" | jq -r '.pending.role')" = "$ROLE" ] || exit 0
    ID=$(hook_child_id)
    [ -n "$ID" ] || exit 0
    save "$(printf '%s' "$DATA" | jq --arg id "$ID" '.pending.id = $id')"
    ;;
  SubagentStop)
    ID=$(hook_child_id)
    [ -n "$ID" ] && [ "$ID" = "$(printf '%s' "$DATA" | jq -r '.pending.id')" ] || exit 0
    [ "$(hook_child_role)" = "$(printf '%s' "$DATA" | jq -r '.pending.role')" ] || exit 0
    RESULT=$(hook_last_message)
    # JSON以外・incomplete・未確認範囲ありは受理しない。指摘の採否はメインが判断する。
    if clean && tracked_paths && [ "$(head)" = "$(printf '%s' "$DATA" | jq -r '.pending.brief.review_head')" ] &&
       printf '%s' "$DATA" | jq -e --arg raw "$RESULT" '
         ($raw | fromjson) as $r |
         .pending.generation == .generation and
         $r.status == "reviewed" and $r.review_base == .pending.brief.review_base and
         $r.review_head == .pending.brief.review_head and
         $r.request_id == .pending.request_id and
         $r.unchecked == [] and ($r.findings | type == "array") and
         all($r.findings[];
           type == "object" and
           (.severity == "critical" or .severity == "high" or .severity == "medium" or .severity == "low") and
           (.path | type == "string" and test("\\S")) and
           (.line | type == "number" and floor == . and . > 0) and
           all(.condition,.impact,.evidence; type == "string" and test("\\S"))
         )' >/dev/null; then
      save "$(printf '%s' "$DATA" | jq --argjson result "$RESULT" '.result = $result | del(.pending)')"
    fi
    ;;
esac
exit 0
