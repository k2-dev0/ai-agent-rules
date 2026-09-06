#!/bin/bash
# 下位モデルの専用implementerだけを、subagent起動前に検証する。
set -eu

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: preflight-implementer.sh <claude|codex>"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"

REPOSITORY=$(git rev-parse --show-toplevel)
case "$1" in
  codex)
    AGENT_FILE="$REPOSITORY/.codex/agents/implementer.toml"
    SKILLS_ROOT=.agents/skills
    [ -f "$AGENT_FILE" ] || die "Codex implementer設定が無い: .codex/agents/implementer.toml"
    grep -Fxq 'name = "implementer"' "$AGENT_FILE" || die "Codex implementer名が不正"
    grep -Fxq 'model = "gpt-5.6-luna"' "$AGENT_FILE" || die "Codex implementer modelが不正"
    grep -Fxq 'model_reasoning_effort = "max"' "$AGENT_FILE" || die "Codex implementer effortが不正"
    grep -Fxq 'sandbox_mode = "workspace-write"' "$AGENT_FILE" || die "Codex implementer sandboxが不正"
    ;;
  claude)
    AGENT_FILE="$REPOSITORY/.claude/agents/implementer.md"
    SKILLS_ROOT=.claude/skills
    [ -f "$AGENT_FILE" ] || die "Claude implementer設定が無い: .claude/agents/implementer.md"
    grep -Fxq 'name: implementer' "$AGENT_FILE" || die "Claude implementer名が不正"
    grep -Fxq 'model: claude-sonnet-5' "$AGENT_FILE" || die "Claude implementer modelが不正"
    grep -Fxq 'effort: max' "$AGENT_FILE" || die "Claude implementer effortが不正"
    grep -Fxq 'tools: Read, Grep, Glob, Edit, Write, Bash' "$AGENT_FILE" || die "Claude implementer toolsが不正"
    ;;
  *) die "agentはclaudeまたはcodexに限定する" ;;
esac

CONTRACT="$REPOSITORY/$SKILLS_ROOT/IMPLEMENTER_CONTRACT.md"
[ -s "$CONTRACT" ] && [ -r "$CONTRACT" ] || die "implementerの共通実装契約が無い、空、または読めない: $CONTRACT"
grep -Fq "$SKILLS_ROOT/IMPLEMENTER_CONTRACT.md" "$AGENT_FILE" || die "implementer定義から共通実装契約への参照が無い"
[ -s "$REPOSITORY/$SKILLS_ROOT/IMPLEMENTATION_RULES.md" ] || die "共通の設計・実装判断基準が無い"

echo "lower-model-implementer-preflight: $1 ok"
