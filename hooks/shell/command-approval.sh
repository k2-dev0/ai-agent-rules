#!/bin/bash
# 通常commandを許可リスト化せず、境界外の承認をGit保護付き入口へ集約する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$(hook_event_name)" = PermissionRequest ] && [ "$(hook_tool_name)" = Bash ] || exit 0
RESULT=$(printf '%s' "$HOOK_INPUT" | python3 "$(dirname "$0")/git-policy.py" --approval) || hook_permission_deny "境界外の実行経路を検査できません。"
REASON=$(printf '%s' "$RESULT" | jq -r '.error // empty')
[ -z "$REASON" ] || hook_permission_deny "$REASON"
# 棄権して実際のユーザー承認を待つ。hookから自動承認しない。
