#!/bin/bash
# UserPromptSubmit / SessionEnd hook: codex の skill スコープ再現を担う。
# - UserPromptSubmit: workflow skill の明示起動を検知し、セッション別の
#   session marker を作成する（各PreToolUse hookが参照）
# - SessionEnd: 自セッションの marker を削除する（残っても別セッションには無害だが掃除する）
# claude では skill frontmatter hooks が同じ役割を担うため本 hook は棄権する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$HOOK_AGENT" = "codex" ] || exit 0

case "$(hook_event_name)" in
  UserPromptSubmit)
    PROMPT=$(hook_prompt)
    [ -z "$PROMPT" ] && exit 0
    for SKILL in tdd meeting cowlick; do
      if echo "$PROMPT" | grep -q "\$$SKILL"; then
        F=$(hook_skill_session_file "$SKILL")
        mkdir -p "$(dirname "$F")"
        : > "$F"
      fi
    done
    ;;
  SessionEnd)
    rm -f "$(hook_cwd)/.codex/tmp/session."*".$(hook_session_id)"
    rm -f "$(hook_cwd)/.codex/tmp/required-reading."*".$(hook_session_id)"
    ;;
esac
exit 0
