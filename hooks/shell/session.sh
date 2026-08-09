#!/bin/bash
# UserPromptSubmit / SessionEnd hook:
# - SOURCE_REPOSITORY.md がある配布元だけ、その説明をsessionへ一度注入する
# - codexではworkflow skillの明示起動をsession markerへ記録する
# - SessionEndで自sessionのmarkerを掃除する
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"

CWD=$(hook_cwd)
SESSION_ID=$(hook_session_id)
AGENT_TMP="$CWD/.$HOOK_AGENT/tmp"
SOURCE_REPOSITORY_FILE="$CWD/SOURCE_REPOSITORY.md"
SOURCE_REPOSITORY_RECEIPT="$AGENT_TMP/source-repository.$SESSION_ID"

case "$(hook_event_name)" in
  UserPromptSubmit)
    PROMPT=$(hook_prompt)
    [ -z "$PROMPT" ] && exit 0

    if [ -f "$SOURCE_REPOSITORY_FILE" ] && [ ! -f "$SOURCE_REPOSITORY_RECEIPT" ]; then
      mkdir -p "$AGENT_TMP"
      command cat "$SOURCE_REPOSITORY_FILE"
      : > "$SOURCE_REPOSITORY_RECEIPT"
    fi

    if [ "$HOOK_AGENT" = "codex" ]; then
      for SKILL in tdd meeting cowlick; do
        if echo "$PROMPT" | grep -q "\$$SKILL"; then
          F=$(hook_skill_session_file "$SKILL")
          mkdir -p "$(dirname "$F")"
          : > "$F"
        fi
      done
    fi
    ;;
  SessionEnd)
    rm -f "$SOURCE_REPOSITORY_RECEIPT"
    if [ "$HOOK_AGENT" = "codex" ]; then
      rm -f "$CWD/.codex/tmp/session."*".$SESSION_ID"
      rm -f "$CWD/.codex/tmp/required-reading."*".$SESSION_ID"
    fi
    ;;
esac
exit 0
