#!/bin/bash
# 観測可能な操作の直前にだけ親用手順を注入し、専用子にはrole契約だけを渡す。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"

ROOT=$(hook_cwd)
[ -n "$ROOT" ] || ROOT=$PWD

skill_file() {
  local relative=$1 candidate
  for base in "$ROOT/.agents/skills" "$ROOT/.claude/skills" "$ROOT/skills"; do
    candidate="$base/$relative"
    [ ! -f "$candidate" ] || { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

inject_parent_once() {
  local key=$1 session file_list=$2 stamp= content= file receipt state_dir
  session=$(hook_session_id)
  case "$session" in ''|*[!A-Za-z0-9._-]*) hook_deny "操作手順を注入するsession_idを確認できません。" ;; esac
  case "$HOOK_AGENT" in claude) state_dir="$ROOT/.claude/tmp" ;; codex) state_dir="$ROOT/.codex/tmp" ;; esac
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    stamp="$stamp$(cksum "$file")"
    content="$content$(cat "$file")"$'\n'
  done <<< "$file_list"
  receipt="$state_dir/operation-context.$key.$session"
  [ ! -f "$receipt" ] || [ "$(cat "$receipt")" != "$stamp" ] || return 0
  mkdir -p "$state_dir" || hook_deny "操作手順の注入記録を保存できません。"
  printf '%s' "$stamp" > "$receipt" || hook_deny "操作手順の注入記録を保存できません。"
  hook_deny "次の手順をこの操作の直前に注入しました。操作は未実行です。内容を反映して再試行してください。

$content"
}

case "$(hook_event_name)" in
  PreToolUse)
    case "$(hook_tool_name)" in
      Agent|*spawn_agent)
        ROLE=$(hook_agent_type)
        case "$ROLE" in difficulty-evaluator|code-reviewer|deep-reviewer|design-reviewer|nesting-reviewer) ;; *) exit 0 ;; esac
        FILE=$(skill_file SUBAGENT_RULES.md) || hook_deny "SUBAGENT_RULES.mdが見つかりません。"
        FILES=$FILE
        case "$ROLE" in
          code-reviewer|deep-reviewer)
            FILE=$(skill_file INDEPENDENT_REVIEW.md) || hook_deny "INDEPENDENT_REVIEW.mdが見つかりません。"
            FILES="$FILES
$FILE"
            ;;
        esac
        inject_parent_once "launch-$ROLE" "$FILES"
        ;;
    esac
    ;;
  SubagentStart)
    ROLE=$(hook_child_role)
    case "$ROLE" in
      difficulty-evaluator) RELATIVE=DIFFICULTY_CONTRACT.md ;;
      code-reviewer|deep-reviewer) RELATIVE=CODE_REVIEW_CONTRACT.md ;;
      design-reviewer) RELATIVE=ponytail/REVIEW_CONTRACT.md ;;
      nesting-reviewer) RELATIVE=unwind/NESTING_CONTRACT.md ;;
      *) exit 0 ;;
    esac
    FILE=$(skill_file "$RELATIVE") || {
      hook_review_context "専用契約 $RELATIVE が見つかりません。成功扱いせず失敗を返してください。"
      exit 0
    }
    hook_review_context "$(cat "$FILE")"
    ;;
esac

exit 0
