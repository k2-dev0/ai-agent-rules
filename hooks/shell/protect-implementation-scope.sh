#!/bin/bash
# 実装subagentの共有worktree書き込みを、親がactivateした個別file scopeへ限定する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"

REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel 2>/dev/null) || \
  hook_deny "実装scopeのリポジトリを解決できません。"
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"
ACTIVE_DIR="$RECEIPT_DIR/implementation.active"
ACTIVE_SCOPE="$ACTIVE_DIR/scope"
ACTIVE_MODE="$ACTIVE_DIR/mode"
OWNER_FILE="$RECEIPT_DIR/implementation.owner"
TOOL=$(hook_tool_name)

if [ "$TOOL" = "Bash" ] && [ ! -d "$ACTIVE_DIR" ]; then
  case "$(hook_command)" in
    "bash .claude/skills/polish/capture-scope.sh activate "*|\
    "bash .agents/skills/polish/capture-scope.sh activate "*)
      [ -n "$(hook_session_id)" ] || hook_deny "実装scopeをactivateする親sessionを取得できません。"
      mkdir -p "$RECEIPT_DIR" || hook_deny "実装scopeのownerを記録できません。"
      printf '%s\n' "$(hook_session_id)" > "$OWNER_FILE" || hook_deny "実装scopeのownerを記録できません。"
      ;;
  esac
fi

[ -d "$ACTIVE_DIR" ] || exit 0
[ -f "$ACTIVE_SCOPE" ] || hook_deny "実装scopeのactive markerが不完全です。親が復旧してください。"
[ -f "$ACTIVE_MODE" ] || hook_deny "実装scopeのmode markerが不完全です。親が復旧してください。"

EXPECTED_REPOSITORY=$(sed -n '1p' "$ACTIVE_SCOPE")
FEATURE=$(sed -n '2p' "$ACTIVE_SCOPE")
[ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || hook_deny "実装scopeのリポジトリが一致しません。"
[ -n "$FEATURE" ] || hook_deny "実装scopeの機能名が空です。"
MODE=$(sed -n '1p' "$ACTIVE_MODE")
case "$MODE" in
  subagent|parent-fallback) ;;
  *) hook_deny "実装scopeのmodeが不正です。親が復旧してください。" ;;
esac

[ -f "$OWNER_FILE" ] || hook_deny "実装scopeをactivateした親sessionを確認できません。"
OWNER=$(sed -n '1p' "$OWNER_FILE")
SESSION=$(hook_session_id)
[ -n "$SESSION" ] || hook_deny "実装scopeのsessionを取得できません。"

is_implementer_read_command() {
  local prefix
  local quoted_path
  local relative_path

  case "$1" in
    "bash .claude/skills/tdd/implementer-read.sh "*)
      prefix="bash .claude/skills/tdd/implementer-read.sh " ;;
    "bash .agents/skills/tdd/implementer-read.sh "*)
      prefix="bash .agents/skills/tdd/implementer-read.sh " ;;
    *) return 1 ;;
  esac

  quoted_path=${1#"$prefix"}
  case "$quoted_path" in
    \'*\') ;;
    *) return 1 ;;
  esac
  relative_path=${quoted_path#\'}
  relative_path=${relative_path%\'}

  # 外側の一組だけをshell quoteとして認める。内側は単一の正規化済み相対pathに限定する。
  case "$relative_path" in
    ""|.|/*|./*|../*|*/../*|*/..|*//*|*':'*|*'?'*|*'*'*|*' '*|\
    *$'\n'*|*$'\r'*|*$'\t'*|*\'*|*'"'*|*';'*|*'&'*|*'|'*|*'`'*|\
    *'<'*|*'>'*|*'('*|*')'*|*'{'*|*'}'*|*'$'*|*'\'*) return 1 ;;
  esac
  [ "$quoted_path" = "'$relative_path'" ]
}

if [ "$TOOL" = "Bash" ]; then
  COMMAND=$(hook_command)
  case "$COMMAND" in
    "bash .claude/skills/polish/capture-scope.sh deactivate $FEATURE"|\
    "bash .agents/skills/polish/capture-scope.sh deactivate $FEATURE")
      [ "$OWNER" = "$SESSION" ] || \
        hook_deny "実装subagentはscopeをdeactivateできません。"
      exit 0 ;;
    "bash .claude/skills/polish/capture-scope.sh handoff-to-parent $FEATURE"|\
    "bash .agents/skills/polish/capture-scope.sh handoff-to-parent $FEATURE")
      [ "$OWNER" = "$SESSION" ] || hook_deny "実装subagentはparent fallbackへhandoffできません。"
      [ "$MODE" = "subagent" ] || hook_deny "parent fallbackへのhandoffはsubagent modeから一度だけ実行できます。"
      exit 0 ;;
  esac
  is_implementer_read_command "$COMMAND" && exit 0
  hook_deny "実装scopeがactiveな間のshellはimplementer-read.shと親のhandoff/deactivateだけ実行できます。"
fi

case "$TOOL" in
  Edit|Write|NotebookEdit|apply_patch) ;;
  *) exit 0 ;;
esac

if [ "$MODE" = "subagent" ]; then
  [ "$OWNER" != "$SESSION" ] || \
    hook_deny "subagent modeでは親sessionはコードを変更できません。失敗時はhandoff-to-parentを実行してください。"
else
  [ "$OWNER" = "$SESSION" ] || \
    hook_deny "parent-fallback modeでは実装subagentはコードを変更できません。"
fi

FOUND=false
while IFS= read -r FILE; do
  [ -n "$FILE" ] || continue
  FOUND=true
  case "$FILE" in
    /*)
      FILE_PARENT=$(dirname "$FILE")
      [ -d "$FILE_PARENT" ] || hook_deny "実装scope外のpathです: $FILE"
      CANONICAL_PARENT=$(cd "$FILE_PARENT" 2>/dev/null && pwd -P) || hook_deny "実装scope外のpathです: $FILE"
      CANONICAL_FILE="$CANONICAL_PARENT/$(basename "$FILE")"
      case "$CANONICAL_FILE" in
        "$REPOSITORY"/*) RELATIVE_PATH=${CANONICAL_FILE#"$REPOSITORY/"} ;;
        *) hook_deny "実装scope外のpathです: $FILE" ;;
      esac
      ;;
    ./*|../*) hook_deny "実装scope外のpathです: $FILE" ;;
    *) RELATIVE_PATH=$FILE ;;
  esac

  ALLOWED=false
  while IFS= read -r SCOPE_PATH; do
    [ -n "$SCOPE_PATH" ] || continue
    [ "$RELATIVE_PATH" = "$SCOPE_PATH" ] && ALLOWED=true
  done < <(sed -n '4,$p' "$ACTIVE_SCOPE")
  [ "$ALLOWED" = true ] || hook_deny "実装scopeの許可path外を変更できません: $RELATIVE_PATH"
done < <(hook_file_paths)

[ "$FOUND" = true ] || hook_deny "実装scope中の書き込み対象pathを取得できません。"
exit 0
