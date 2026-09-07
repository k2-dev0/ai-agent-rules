#!/bin/bash
# 短い待機を再試行させず補正する。プロセス待機・瞬時snapshotは変更しない。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$HOOK_AGENT" = codex ] || exit 0
case "$(hook_tool_name)" in
  *wait_agent) ;;
  wait|collaborationwait|collaboration.wait|collaboration_wait|functions.wait)
    echo "$HOOK_INPUT" | jq -e '.tool_input.ids | type == "array"' >/dev/null || exit 0
    ;;
  *) exit 0 ;;
esac
echo "$HOOK_INPUT" | jq -e '
  .tool_input | type == "object"
' >/dev/null || exit 0
# 0は明示的な状態確認。型不正・負値はtool本体へ渡し、診断を隠さない。
echo "$HOOK_INPUT" | jq -e '
  .tool_input |
  (has("timeout_ms") | not) or
  (.timeout_ms | if type == "number" then . > 0 and . < 60000 else false end)
' >/dev/null || exit 0
hook_rewrite_input "$(echo "$HOOK_INPUT" | jq -c '.tool_input + {timeout_ms: 60000}')"
