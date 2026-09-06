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

hook_implementer_launch_valid || hook_deny "implementerのモデル・effortは専用定義から読み込みます。起動引数の上書き、resume、background実行は使えません。Codexはfork_context=falseまたはfork_turns=noneを明示してください。"

# 手動preflightを前提にせず、実際の起動直前に配布済み定義を検査する。
REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel) || hook_deny "implementer設定のリポジトリを確認できません。"
case "$HOOK_AGENT" in
  codex)
    AGENT_FILE="$REPOSITORY/.codex/agents/implementer.toml"
    SKILLS_ROOT=.agents/skills
    EXPECTED_SETTINGS='name = "implementer"
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
sandbox_mode = "workspace-write"'
    [ -r "$AGENT_FILE" ] || hook_deny "Codex implementer設定が無い、または読めません。"
    SETTINGS=$(sed '/^developer_instructions[[:space:]]*=/,$d' "$AGENT_FILE")
    ;;
  claude)
    AGENT_FILE="$REPOSITORY/.claude/agents/implementer.md"
    SKILLS_ROOT=.claude/skills
    EXPECTED_SETTINGS='name: implementer
model: claude-sonnet-5
effort: max
tools: Read, Grep, Glob, Edit, Write, Bash'
    [ -r "$AGENT_FILE" ] || hook_deny "Claude implementer設定が無い、または読めません。"
    SETTINGS=$(awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$AGENT_FILE")
    ;;
esac
while IFS= read -r EXPECTED; do
  KEY=${EXPECTED%%[: =]*}
  ACTUAL=$(printf '%s\n' "$SETTINGS" | grep -E "^$KEY[[:space:]]*[:=]")
  [ "$ACTUAL" = "$EXPECTED" ] || hook_deny "implementer定義の $KEY が配布設定と一致しません。必要な設定: $EXPECTED"
done <<< "$EXPECTED_SETTINGS"

CONTRACT="$REPOSITORY/$SKILLS_ROOT/IMPLEMENTER_CONTRACT.md"
[ -s "$CONTRACT" ] && [ -r "$CONTRACT" ] || hook_deny "implementerの共通実装契約が無い、空、または読めません。"
grep -Fq "$SKILLS_ROOT/IMPLEMENTER_CONTRACT.md" "$AGENT_FILE" || hook_deny "implementer定義から共通実装契約への参照がありません。"
[ -s "$REPOSITORY/$SKILLS_ROOT/IMPLEMENTATION_RULES.md" ] && [ -r "$REPOSITORY/$SKILLS_ROOT/IMPLEMENTATION_RULES.md" ] || hook_deny "共通の設計・実装判断基準が無い、空、または読めません。"

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
