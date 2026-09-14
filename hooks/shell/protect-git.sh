#!/bin/bash
# .gitのpath検査とGit読み取り引数の検査。任意script内部の保護はOS sandboxが担う。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
command -v python3 >/dev/null 2>&1 || hook_deny ".git保護に必要なpython3がありません。"
OUTPUT=$(printf '%s' "$HOOK_INPUT" | python3 "$(dirname "$0")/git-policy.py") || hook_deny ".git保護の検査に失敗しました。"
[ -n "$OUTPUT" ] || exit 0
REASON=$(printf '%s' "$OUTPUT" | jq -r '.error // empty')
[ -z "$REASON" ] || hook_deny "$REASON"
COMMAND=$(printf '%s' "$OUTPUT" | jq -er '.command | select(type == "string" and length > 0)') || hook_deny ".git保護の返却値が不正です。"
COMMIT_CHECK=$(printf '%s' "$OUTPUT" | jq -r '.commit_check // empty')
if [ -n "$COMMIT_CHECK" ]; then
  INPUT=$(printf '%s' "$HOOK_INPUT" | jq --arg command "$COMMIT_CHECK" '.tool_input.command = $command')
  GUARD=$(cd "$(dirname "$0")" && pwd)/commit-gate.sh
  DECISION=$(cd "$(hook_cwd)" && printf '%s' "$INPUT" | bash "$GUARD") || hook_deny "commit契約を確認できません。"
  if [ -n "$DECISION" ]; then
    printf '%s\n' "$DECISION"
    exit 0
  fi
fi
hook_rewrite_command "$COMMAND"
