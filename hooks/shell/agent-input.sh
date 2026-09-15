#!/bin/bash
# Native input lifecycle; hook JSON remains owned by hook-io.sh.
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$HOOK_AGENT" = codex ] || exit 0
RESULT=$(printf '%s' "$HOOK_INPUT" | python3 "$(dirname "$0")/agent-input.py" hook 2>&1) || {
  [ "$(hook_event_name)" != PreToolUse ] || hook_deny "$RESULT"
  exit 0
}
if [ "$(hook_event_name)" = PreToolUse ] && [ -n "$RESULT" ]; then
  hook_rewrite_command "$RESULT"
fi
