#!/bin/bash
# 非同期workerの予約・結果照合。失敗時は予約を残し、親の変更を止める。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$HOOK_AGENT" = codex ] || exit 0
if . "$(dirname "$0")/git-safe-env.sh"; then
  RESULT=$(printf '%s' "$HOOK_INPUT" | python3 "$(dirname "$0")/deepseek-worker.py") || RESULT='{"error":"worker guard could not run"}'
else
  RESULT='{"error":"worker Git environment could not be protected"}'
fi
[ -n "$RESULT" ] || exit 0
REASON=$(printf '%s' "$RESULT" | jq -er '.error | select(type == "string" and length > 0)') || REASON='invalid worker guard result'
if [ "$(hook_event_name)" = PreToolUse ]; then
  hook_deny "DeepSeek worker guard: $REASON"
fi
hook_post_stop "DeepSeek worker guard: $REASON"
