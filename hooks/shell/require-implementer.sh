#!/bin/bash
# 並列起動と実装委任を拒否し、専用reviewerの設定を検査する。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"

hook_serial_agent_launch_valid || hook_deny "並列実行は禁止です。background・一括起動・resumeを使わず、子の完了後に次へ進んでください。"
ROLE=$(hook_agent_type)
[ "$ROLE" != implementer ] || hook_deny "実装委任は禁止です。メインで実装してください。"
if [ "$ROLE" = nesting-reviewer ]; then
  hook_nesting_launch_valid || hook_deny "nesting-reviewerは専用定義で新規起動してください。モデル・effort上書き、resume、background、文脈継承は使えません。"
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
