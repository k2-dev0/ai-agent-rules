#!/bin/bash
# native子の用途・直列起動と専用reviewerの設定を検査する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"

# 旧skill内の全tool登録が残っていても、起動以外は対象にしない。
case "$(hook_tool_name)" in
  Read|Edit|Write|apply_patch|switch_model|Bash) exit 0 ;;
  *send_input|*send_message|*send_message_to_agent|*followup_task|*resume_agent|*spawn_agents_on_csv)
    hook_deny "子への追送・再開・一括起動は禁止です。入力を訂正し、専用roleで新規起動してください。" ;;
  Agent|*spawn_agent) ;;
  *) hook_deny "専用roleを指定する起動toolを確認できません。" ;;
esac
hook_serial_agent_launch_valid || hook_deny "並列実行は禁止です。background・一括起動・resumeを使わず、子の完了後に次へ進んでください。"
ROLE=$(hook_agent_type)
[ "$ROLE" != implementer ] || hook_deny "native子への実装委任は禁止です。CodexはDeepSeek MCP、Claudeはメインで実装してください。"
if [ "$HOOK_AGENT" = codex ]; then
  case "$ROLE" in
    code-reviewer|design-reviewer) ;;
    *) hook_deny "Codexの子はcode-reviewer・design-reviewerの専用roleだけです。調査・実装・ネスト候補抽出はDeepSeek MCPを使ってください。" ;;
  esac
fi
case "$ROLE" in
  difficulty-evaluator|code-reviewer|design-reviewer|nesting-reviewer) ;;
  *) hook_deny "子は難易度調査・独立コードレビュー・設計監査・ネスト候補抽出の専用roleだけ起動できます。方針決定の調査・実装はメインで行ってください。" ;;
esac
REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel) || hook_deny "子のリポジトリを確認できません。"
SKILLS_ROOT=.claude/skills
[ "$HOOK_AGENT" != codex ] || SKILLS_ROOT=.agents/skills
[ -s "$REPOSITORY/$SKILLS_ROOT/CHILD_RULES.md" ] || hook_deny "子の共通制約がありません。"
case "$ROLE" in
  difficulty-evaluator|code-reviewer|design-reviewer)
    hook_review_launch_valid "$ROLE" || hook_deny "reviewerは専用定義で新規起動してください。設定上書き・文脈継承は禁止です。"
    REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel) || hook_deny "reviewerのリポジトリを確認できません。"
    EFFORT=high
    case "$HOOK_AGENT:$ROLE" in
      *:difficulty-evaluator) EFFORT=medium ;;
      codex:*) EFFORT=xhigh ;;
    esac
    if [ "$ROLE" = difficulty-evaluator ]; then
      BRIEF=
      BRIEF=$(hook_review_brief 2>&1) || hook_deny "難易度調査はrepositoryとimplementation_policyだけのJSONを渡してください。$BRIEF"
      if [ -n "$BRIEF" ]; then
        printf '%s' "$BRIEF" | jq -e --arg root "$REPOSITORY" '
          keys == ["implementation_policy", "repository"] and .repository == $root and
          (.implementation_policy | type == "string" and test("\\S"))
        ' >/dev/null || hook_deny "難易度調査は現在repositoryの絶対pathと実装方針本文だけを渡してください。"
        printf '%s' "$BRIEF" | jq -e '
          .implementation_policy | length <= 4000
        ' >/dev/null || hook_deny "implementation_policy exceeds 4000 characters"
      fi
    fi
    if [ "$HOOK_AGENT" = codex ]; then
      AGENT_FILE="$REPOSITORY/.codex/agents/$ROLE.toml"
      CONTRACT=.agents/skills/CODE_REVIEW_CONTRACT.md
      [ "$ROLE" != design-reviewer ] || CONTRACT=.agents/skills/ponytail/REVIEW_CONTRACT.md
      MODEL=gpt-6-astra
      EXPECTED_SETTINGS="name = \"$ROLE\"
model = \"$MODEL\"
model_reasoning_effort = \"$EFFORT\"
sandbox_mode = \"read-only\""
      [ -r "$AGENT_FILE" ] || hook_deny "reviewer定義が無い、または読めません。"
      SETTINGS=$(sed '/^developer_instructions[[:space:]]*=/,$d' "$AGENT_FILE")
      [ "$(sed -n '/^\[agents\]$/,$p' "$AGENT_FILE")" = $'[agents]\nenabled = false' ] || hook_deny "reviewerの再委任は禁止です。"
    else
      AGENT_FILE="$REPOSITORY/.claude/agents/$ROLE.md"
      CONTRACT=.claude/skills/CODE_REVIEW_CONTRACT.md
      [ "$ROLE" != design-reviewer ] || CONTRACT=.claude/skills/ponytail/REVIEW_CONTRACT.md
      [ "$ROLE" != difficulty-evaluator ] || CONTRACT=.claude/skills/DIFFICULTY_CONTRACT.md
      EXPECTED_SETTINGS="name: $ROLE
model: opus
effort: $EFFORT
tools: Read, Grep, Glob, Bash"
      [ -r "$AGENT_FILE" ] || hook_deny "reviewer定義が無い、または読めません。"
      SETTINGS=$(awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$AGENT_FILE")
    fi
    while IFS= read -r EXPECTED; do
      KEY=${EXPECTED%%[: =]*}
      ACTUAL=$(printf '%s\n' "$SETTINGS" | grep -E "^$KEY[[:space:]]*[:=]")
      [ "$ACTUAL" = "$EXPECTED" ] || hook_deny "reviewer定義の $KEY が配布設定と一致しません。"
    done <<< "$EXPECTED_SETTINGS"
    [ -s "$REPOSITORY/$CONTRACT" ] || hook_deny "reviewerの契約がありません。"
    [ -x "$REPOSITORY/.$HOOK_AGENT/hooks/shell/load-operation-context.sh" ] || hook_deny "reviewerの契約注入hookがありません。"
    if [ "$ROLE" = difficulty-evaluator ]; then
      hook_reserve_agent_input "$BRIEF" || hook_deny "難易度調査の入力を専用子へ予約できません。新規入力の準備と先行子の完了を確認してください。"
    fi
    exit 0
    ;;
esac
if [ "$ROLE" = nesting-reviewer ]; then
  hook_review_launch_valid nesting-reviewer || hook_deny "nesting-reviewerは専用定義で新規起動してください。モデル・effort上書き、resume、background、文脈継承は使えません。"
  REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel) || hook_deny "nesting-reviewerのリポジトリを確認できません。"
  AGENT_FILE="$REPOSITORY/.claude/agents/nesting-reviewer.md"
  SKILLS_ROOT=.claude/skills
  EXPECTED_SETTINGS='name: nesting-reviewer
model: claude-sonnet-5
effort: max
tools: Read, Grep, Glob'
  SETTINGS=$(awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$AGENT_FILE")
  [ -r "$AGENT_FILE" ] || hook_deny "nesting-reviewer定義が無い、または読めません。"
  while IFS= read -r EXPECTED; do
    KEY=${EXPECTED%%[: =]*}
    ACTUAL=$(printf '%s\n' "$SETTINGS" | grep -E "^$KEY[[:space:]]*[:=]")
    [ "$ACTUAL" = "$EXPECTED" ] || hook_deny "nesting-reviewer定義の $KEY が配布設定と一致しません。"
  done <<< "$EXPECTED_SETTINGS"
  CONTRACT="$SKILLS_ROOT/unwind/NESTING_CONTRACT.md"
  [ -s "$REPOSITORY/$CONTRACT" ] && [ -r "$REPOSITORY/$CONTRACT" ] || hook_deny "nesting-reviewerの検出契約がありません。"
  [ -x "$REPOSITORY/.$HOOK_AGENT/hooks/shell/load-operation-context.sh" ] || hook_deny "nesting-reviewerの契約注入hookがありません。"
  exit 0
fi

exit 0
