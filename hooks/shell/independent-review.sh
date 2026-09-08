#!/bin/bash
# 最初のコード編集前のHEADと、専用子の固定入力・最終結果をsession別に保持する。
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
    [ "$EVENT" != Stop ] || hook_stop_block "独立レビュー未完了: session_idを確定できません。"
    exit 0 ;;
esac
STATE_DIR="$ROOT/.$HOOK_AGENT/tmp"
STATE="$STATE_DIR/independent-review.$SESSION.json"
CONTRACT="$ROOT/.agents/skills/INDEPENDENT_REVIEW.md"
[ "$HOOK_AGENT" != claude ] || CONTRACT="$ROOT/.claude/skills/INDEPENDENT_REVIEW.md"

fail() {
  if [ "$EVENT" = PreToolUse ]; then hook_deny "$1"; fi
  hook_stop_block "$1"
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
[ ! -L "$STATE" ] || fail "独立レビュー状態がsymlinkです。"
DATA='{}'
if [ -f "$STATE" ]; then
  DATA=$(cat "$STATE")
  printf '%s' "$DATA" | jq -e 'type == "object" and (.base | type == "string")' >/dev/null || fail "独立レビュー状態が壊れています。"
fi
case "$EVENT" in
  UserPromptSubmit)
    [ -f "$STATE" ] || exit 0
    # 新しい依頼・訂正は同一HEADでも旧結果を失効させる。未完了の比較元は保持する。
    if printf '%s' "$DATA" | jq -e '.finished == true' >/dev/null && clean && [ "$(head)" = "$(printf '%s' "$DATA" | jq -r '.finished_head')" ]; then
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
        while IFS= read -r FILE; do
          code_path "$FILE" && REQUIRED=true
        done <<< "$PATHS"
        [ "$REQUIRED" = true ] || exit 0
        FIRST=false
        if [ ! -f "$STATE" ]; then
          FIRST=true
          BASE=$(head) || hook_deny "変更前HEADがありません。初期commitを作成してから編集してください。"
          DATA=$(jq -cn --arg base "$BASE" '{base:$base,generation:0,paths:[]}')
        fi
        save "$(printf '%s' "$DATA" | jq --arg paths "$PATHS" '.paths = (((.paths // []) + ($paths | split("\n"))) | unique) | .required = true | .finished = false | del(.result, .pending)')"
        [ "$FIRST" = false ] || hook_deny "変更前HEADを $STATE に保存しました（review_base=$BASE）。編集はまだ実行していません。同じ編集を再試行し、検証・整形・commit後、完了報告前に $CONTRACT を読んでください。"
        ;;
      Agent|*spawn_agent)
        ROLE=$(hook_agent_type)
        case "$ROLE" in code-reviewer|deep-reviewer) ;; *) exit 0 ;; esac
        BRIEF=$(hook_review_brief) || hook_deny "コードレビューのpromptはrepository・review_base・review_head・requirementsを持つJSONにしてください。起動直前に $CONTRACT を読んでください。"
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
        save "$(printf '%s' "$DATA" | jq --argjson brief "$BRIEF" --arg role "$ROLE" --arg request_id "$REQUEST_ID" '.pending = {brief:$brief,role:$role,request_id:$request_id,generation:(.generation // 0)} | del(.result)')"
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
    hook_review_context "最終JSONのrequest_idには $(printf '%s' "$DATA" | jq -r '.pending.request_id') を入れてください。要求本文の再掲は不要です。"
    ;;
  SubagentStop)
    ID=$(hook_child_id)
    [ -n "$ID" ] && [ "$ID" = "$(printf '%s' "$DATA" | jq -r '.pending.id')" ] || exit 0
    [ "$(hook_child_role)" = "$(printf '%s' "$DATA" | jq -r '.pending.role')" ] || exit 0
    RESULT=$(hook_last_message)
    # JSON以外・incomplete・未確認範囲ありは受理しない。指摘の採否はメインが判断する。
    if clean && [ "$(head)" = "$(printf '%s' "$DATA" | jq -r '.pending.brief.review_head')" ] &&
       printf '%s' "$DATA" | jq -e --arg raw "$RESULT" '
         ($raw | fromjson) as $r |
         .pending.generation == .generation and
         $r.status == "reviewed" and $r.review_base == .pending.brief.review_base and
         $r.review_head == .pending.brief.review_head and
         $r.request_id == .pending.request_id and
         $r.unchecked == [] and ($r.findings | type == "array")' >/dev/null; then
      save "$(printf '%s' "$DATA" | jq --argjson result "$RESULT" '.result = $result | del(.pending)')"
    fi
    ;;
  Stop)
    [ -f "$STATE" ] || exit 0
    printf '%s' "$DATA" | jq -e '.required == true' >/dev/null || exit 0
    # 相談・失敗の報告は完了にしない。未完了stateを残して次の依頼へ持ち越す。
    DATA=$(printf '%s' "$DATA" | jq '.finished = false')
    save "$DATA"
    MESSAGE=$(hook_last_message)
    if printf '%s\n' "$MESSAGE" | grep -Eq '^(独立レビュー未完了|作業保留): .+'; then exit 0; fi
    HEAD=$(head) || fail "独立レビュー未完了: HEADを確認できません。"
    UNTRACKED=false
    while IFS= read -r FILE; do
      case "$FILE" in "$ROOT"/*) FILE=${FILE#"$ROOT"/} ;; esac
      if [ -e "$ROOT/$FILE" ] && ! git -C "$ROOT" ls-files --error-unmatch -- "$FILE" >/dev/null; then UNTRACKED=true; fi
    done < <(printf '%s' "$DATA" | jq -r '.paths[]')
    if [ "$UNTRACKED" = false ] && clean && git -C "$ROOT" diff --quiet "$(printf '%s' "$DATA" | jq -r '.base')"; then
      save "$(printf '%s' "$DATA" | jq --arg head "$HEAD" '.finished = true | .finished_head = $head')"
      exit 0
    fi
    if [ "$UNTRACKED" = false ] && clean && printf '%s' "$DATA" | jq -e --arg head "$HEAD" '.result.status == "reviewed" and .result.review_head == $head' >/dev/null; then
      save "$(printf '%s' "$DATA" | jq --arg head "$HEAD" '.finished = true | .finished_head = $head')"
      exit 0
    fi
    fail "独立レビューが未完了です。起動直前に $CONTRACT を読み、review_base=$(printf '%s' "$DATA" | jq -r '.base') と現在HEADで実行してください。相談・実行不能なら『作業保留: 理由』または『独立レビュー未完了: 理由』を独立した行で報告し、完了扱いにしないでください。"
    ;;
esac
exit 0
