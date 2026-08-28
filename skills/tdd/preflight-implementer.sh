#!/bin/bash
# native surveyorと専用implementerの権限境界を、subagent起動前に検証する。
set -eu

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: preflight-implementer.sh <claude|codex>"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"

REPOSITORY=$(git rev-parse --show-toplevel)
case "$1" in
  codex)
    AGENT_FILE="$REPOSITORY/.codex/agents/implementer.toml"
    [ -f "$AGENT_FILE" ] || die "Codex implementer設定が無い: .codex/agents/implementer.toml"
    grep -Fxq 'name = "implementer"' "$AGENT_FILE" || die "Codex implementer名が不正"
    grep -Fxq 'model = "gpt-5.6-luna"' "$AGENT_FILE" || die "Codex implementer modelが不正"
    grep -Fxq 'model_reasoning_effort = "max"' "$AGENT_FILE" || die "Codex implementer effortが不正"
    grep -Fxq 'sandbox_mode = "workspace-write"' "$AGENT_FILE" || die "Codex implementer sandboxが不正"
    grep -Fq '要求に直接必要なproduction code' "$AGENT_FILE" || die "Codex implementerの探索契約が無い"
    ! grep -Fq 'implementer-read.sh' "$AGENT_FILE" || die "Codex implementerに旧quoted reader契約が残存"
    SURVEYOR_FILE="$REPOSITORY/.codex/agents/surveyor.toml"
    [ -f "$SURVEYOR_FILE" ] || die "Codex surveyor設定が無い: .codex/agents/surveyor.toml"
    grep -Fxq 'name = "surveyor"' "$SURVEYOR_FILE" || die "Codex surveyor名が不正"
    grep -Fxq 'sandbox_mode = "read-only"' "$SURVEYOR_FILE" || die "Codex surveyorがread-onlyではない"
    ;;
  claude)
    AGENT_FILE="$REPOSITORY/.claude/agents/implementer.md"
    [ -f "$AGENT_FILE" ] || die "Claude implementer設定が無い: .claude/agents/implementer.md"
    grep -Fxq 'name: implementer' "$AGENT_FILE" || die "Claude implementer名が不正"
    grep -Fxq 'model: claude-sonnet-5' "$AGENT_FILE" || die "Claude implementer modelが不正"
    grep -Fxq 'effort: max' "$AGENT_FILE" || die "Claude implementer effortが不正"
    grep -Fxq 'tools: Read, Grep, Glob, Edit, Write' "$AGENT_FILE" || die "Claude implementer toolsが不正"
    grep -Fq '要求に直接必要なproduction code' "$AGENT_FILE" || die "Claude implementerの探索契約が無い"
    SURVEYOR_FILE="$REPOSITORY/.claude/agents/surveyor.md"
    [ -f "$SURVEYOR_FILE" ] || die "Claude surveyor設定が無い: .claude/agents/surveyor.md"
    grep -Fxq 'name: surveyor' "$SURVEYOR_FILE" || die "Claude surveyor名が不正"
    grep -Fxq 'tools: Read, Grep, Glob' "$SURVEYOR_FILE" || die "Claude surveyorがread-onlyではない"
    ;;
  *) die "agentはclaudeまたはcodexに限定する" ;;
esac

grep -Fq 'path:line' "$SURVEYOR_FILE" || die "surveyorの根拠契約が無い"
echo "native-agents-preflight: $1 ok"
