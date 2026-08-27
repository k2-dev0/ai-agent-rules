#!/bin/bash
# UserPromptSubmit / SessionEnd hook: codex の skill スコープ再現を担う。
# - UserPromptSubmit: workflow skill の明示起動を検知し、セッション別の
#   session marker を作成する（各PreToolUse hookが参照）
# - SessionEnd: 自セッションの marker を削除し、所有中の実装scopeを回収可能にする
# claude では skill frontmatter hooks が同じ役割を担うため本 hook は棄権する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$HOOK_AGENT" = "codex" ] || exit 0

case "$(hook_event_name)" in
  UserPromptSubmit)
    PROMPT=$(hook_prompt)
    [ -z "$PROMPT" ] && exit 0
    for SKILL in tdd errand meeting cowlick; do
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
    REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel 2>/dev/null) || exit 0
    SCOPE_STATE_LIBRARY=
    for CANDIDATE in \
      "$REPOSITORY/.agents/skills/polish/implementation-scope-state.sh" \
      "$REPOSITORY/.claude/skills/polish/implementation-scope-state.sh" \
      "$REPOSITORY/skills/polish/implementation-scope-state.sh"; do
      if [ -f "$CANDIDATE" ]; then
        SCOPE_STATE_LIBRARY=$CANDIDATE
        break
      fi
    done
    [ -n "$SCOPE_STATE_LIBRARY" ] || exit 0
    . "$SCOPE_STATE_LIBRARY"
    implementation_scope_init "$REPOSITORY"
    [ -f "$IMPLEMENTATION_ACTIVE_SCOPE" ] || exit 0
    [ -f "$IMPLEMENTATION_ACTIVE_MODE" ] || exit 0
    [ -f "$IMPLEMENTATION_ACTIVE_REQUEST" ] || exit 0
    [ -f "$IMPLEMENTATION_OWNER_FILE" ] || exit 0
    [ "$(sed -n '1p' "$IMPLEMENTATION_OWNER_FILE")" = "$(hook_session_id)" ] || exit 0
    case "$(sed -n '1p' "$IMPLEMENTATION_ACTIVE_MODE")" in
      subagent|parent-fallback) ;;
      *) exit 0 ;;
    esac
    TEMP_MODE="$IMPLEMENTATION_ACTIVE_MODE.tmp.$$"
    printf 'orphaned\n' > "$TEMP_MODE" || exit 0
    mv "$TEMP_MODE" "$IMPLEMENTATION_ACTIVE_MODE" || exit 0
    implementation_scope_touch_lease || true
    ;;
esac
exit 0
