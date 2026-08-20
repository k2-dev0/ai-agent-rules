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

EXPECTED_REPOSITORY=$(sed -n '1p' "$ACTIVE_SCOPE")
FEATURE=$(sed -n '2p' "$ACTIVE_SCOPE")
[ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || hook_deny "実装scopeのリポジトリが一致しません。"
[ -n "$FEATURE" ] || hook_deny "実装scopeの機能名が空です。"

if [ "$TOOL" = "Bash" ]; then
  COMMAND=$(hook_command)
  case "$COMMAND" in
    "bash .claude/skills/polish/capture-scope.sh deactivate $FEATURE"|\
    "bash .agents/skills/polish/capture-scope.sh deactivate $FEATURE")
      [ -f "$OWNER_FILE" ] || hook_deny "実装scopeをactivateした親sessionを確認できません。"
      [ "$(sed -n '1p' "$OWNER_FILE")" = "$(hook_session_id)" ] || \
        hook_deny "実装subagentはscopeをdeactivateできません。"
      exit 0 ;;
  esac
  hook_deny "実装subagentのscopeがactiveな間はshellを実行できません。subagent完了後に親がscopeをdeactivateしてください。"
fi

case "$TOOL" in
  Edit|Write|NotebookEdit|apply_patch) ;;
  *) exit 0 ;;
esac

[ -f "$OWNER_FILE" ] || hook_deny "実装scopeをactivateした親sessionを確認できません。"
[ "$(sed -n '1p' "$OWNER_FILE")" != "$(hook_session_id)" ] || \
  hook_deny "実装scopeがactiveな間は親sessionもコードを変更できません。専用implementerの完了後にdeactivateしてください。"

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
  [ "$ALLOWED" = true ] || hook_deny "実装subagentは許可path外を変更できません: $RELATIVE_PATH"
done < <(hook_file_paths)

[ "$FOUND" = true ] || hook_deny "実装scope中の書き込み対象pathを取得できません。"
exit 0
