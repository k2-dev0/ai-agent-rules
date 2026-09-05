#!/bin/bash
# 実装workflowのAgent起動は専用implementerに限定する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"

ROLE=$(hook_agent_type)
WORKFLOW=false
[ "${1:-}" = workflow ] && WORKFLOW=true
if [ "$HOOK_AGENT" = codex ] && { hook_skill_session_active tdd || hook_skill_session_active errand; }; then
  WORKFLOW=true
fi

if [ "$WORKFLOW" = true ] && [ "$ROLE" != implementer ]; then
  hook_deny "実装workflowでは専用implementerを選択してください。Codexはagent_type、Claudeはsubagent_typeにimplementerを指定します。task名やLuna/maxの指定だけでは代用できません。"
fi
[ "$ROLE" = implementer ] || exit 0

MODE=$(hook_permission_mode)
if [ "$HOOK_AGENT" = codex ]; then
  TRANSCRIPT=$(hook_transcript_path)
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    SANDBOX=$(jq -r 'select(.type == "turn_context") | .payload.sandbox_policy.type // empty' "$TRANSCRIPT" | tail -n 1)
    [ "$SANDBOX" = read-only ] && MODE=read-only
  fi
fi
case "$MODE" in
  read-only|plan)
    hook_deny "親タスクが読み取り専用です。専用implementerも親の実効権限を継承するため、編集ごとの承認は起動では解消しません。親側で必要な書き込み権限を一度確認してから再開してください。"
    ;;
esac
exit 0
