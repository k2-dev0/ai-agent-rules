#!/bin/bash
# 並列起動と実装委任を拒否し、専用reviewerの設定を検査する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"

# 旧skill内の全tool登録が残っていても、起動以外は対象にしない。
case "$(hook_tool_name)" in
  Read|Edit|Write|apply_patch|switch_model|Bash) exit 0 ;;
esac
hook_serial_agent_launch_valid || hook_deny "並列実行は禁止です。background・一括起動・resumeを使わず、子の完了後に次へ進んでください。"
ROLE=$(hook_agent_type)
[ "$ROLE" != implementer ] || hook_deny "実装委任は禁止です。メインで実装してください。"
case "$ROLE" in
  difficulty-evaluator|code-reviewer|deep-reviewer|design-reviewer|nesting-reviewer) ;;
  *) hook_deny "子は難易度調査・独立コードレビュー・設計監査・ネスト候補抽出の専用roleだけ起動できます。方針決定の調査・実装はメインで行ってください。" ;;
esac
case "$ROLE" in
  difficulty-evaluator|code-reviewer|deep-reviewer|design-reviewer)
    hook_review_launch_valid "$ROLE" || hook_deny "reviewerは専用定義で新規起動してください。設定上書き・文脈継承は禁止です。"
    REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel) || hook_deny "reviewerのリポジトリを確認できません。"
    EFFORT=high
    if [ "$ROLE" = difficulty-evaluator ]; then
      EFFORT=medium
      case "$HOOK_AGENT:$(hook_tool_name)" in
        codex:*spawn_agent)
          hook_agent_message_valid || hook_deny "Codexの難易度調査はspawn_agentのmessageに依頼を渡してください。promptは併用しないでください。"
          ;;
        *)
          BRIEF=$(hook_review_brief) || hook_deny "難易度調査はrepositoryとimplementation_policyだけのJSONを渡してください。"
          printf '%s' "$BRIEF" | jq -e --arg root "$REPOSITORY" '
            keys == ["implementation_policy", "repository"] and .repository == $root and
            (.implementation_policy | type == "string" and test("\\S"))
          ' >/dev/null || hook_deny "難易度調査は現在repositoryの絶対pathと実装方針本文だけを渡してください。"
          ;;
      esac
    fi
    if [ "$HOOK_AGENT" = codex ]; then
      AGENT_FILE="$REPOSITORY/.codex/agents/$ROLE.toml"
      CONTRACT=.agents/skills/CODE_REVIEW_CONTRACT.md
      [ "$ROLE" != design-reviewer ] || CONTRACT=.agents/skills/ponytail/REVIEW_CONTRACT.md
      [ "$ROLE" != difficulty-evaluator ] || CONTRACT=.agents/skills/DIFFICULTY_CONTRACT.md
      MODEL=gpt-5.6-sol
      [ "$ROLE" = code-reviewer ] || MODEL=gpt-6-astra
      EXPECTED_SETTINGS="name = \"$ROLE\"
model = \"$MODEL\"
model_reasoning_effort = \"$EFFORT\"
sandbox_mode = \"read-only\""
      [ -r "$AGENT_FILE" ] || hook_deny "reviewer定義が無い、または読めません。"
      SETTINGS=$(sed '/^developer_instructions[[:space:]]*=/,$d' "$AGENT_FILE")
      grep -Fxq 'enabled = false' "$AGENT_FILE" || hook_deny "reviewerの再委任は禁止です。"
    else
      [ "$ROLE" != deep-reviewer ] || hook_deny "Claudeのコードレビューはcode-reviewerを使ってください。"
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
    [ -s "$REPOSITORY/$CONTRACT" ] && grep -Fq "$CONTRACT" "$AGENT_FILE" || hook_deny "reviewerの契約が無い、または参照されていません。"
    exit 0
    ;;
esac
if [ "$ROLE" = nesting-reviewer ]; then
  hook_review_launch_valid nesting-reviewer || hook_deny "nesting-reviewerは専用定義で新規起動してください。モデル・effort上書き、resume、background、文脈継承は使えません。"
  REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel) || hook_deny "nesting-reviewerのリポジトリを確認できません。"
  case "$HOOK_AGENT" in
    codex)
      AGENT_FILE="$REPOSITORY/.codex/agents/nesting-reviewer.toml"
      SKILLS_ROOT=.agents/skills
      EXPECTED_SETTINGS='name = "nesting-reviewer"
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
sandbox_mode = "read-only"'
      SETTINGS=$(sed '/^developer_instructions[[:space:]]*=/,$d' "$AGENT_FILE")
      ;;
    claude)
      AGENT_FILE="$REPOSITORY/.claude/agents/nesting-reviewer.md"
      SKILLS_ROOT=.claude/skills
      EXPECTED_SETTINGS='name: nesting-reviewer
model: claude-sonnet-5
effort: max
tools: Read, Grep, Glob'
      SETTINGS=$(awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$AGENT_FILE")
      ;;
  esac
  [ -r "$AGENT_FILE" ] || hook_deny "nesting-reviewer定義が無い、または読めません。"
  while IFS= read -r EXPECTED; do
    KEY=${EXPECTED%%[: =]*}
    ACTUAL=$(printf '%s\n' "$SETTINGS" | grep -E "^$KEY[[:space:]]*[:=]")
    [ "$ACTUAL" = "$EXPECTED" ] || hook_deny "nesting-reviewer定義の $KEY が配布設定と一致しません。"
  done <<< "$EXPECTED_SETTINGS"
  CONTRACT="$SKILLS_ROOT/unwind/NESTING_CONTRACT.md"
  [ -s "$REPOSITORY/$CONTRACT" ] && [ -r "$REPOSITORY/$CONTRACT" ] && grep -Fq "$CONTRACT" "$AGENT_FILE" || hook_deny "nesting-reviewerの検出契約が無い、または参照されていません。"
  exit 0
fi

exit 0
