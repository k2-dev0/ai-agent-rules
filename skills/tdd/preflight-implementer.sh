#!/bin/bash
# 専用implementerの定義と安全な読み取り経路を、scope activate前に検証する。
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
    grep -Fq 'implementer-read.sh' "$AGENT_FILE" || die "Codex implementerに安全な読み取り契約が無い"
    SKILLS_ROOT="$REPOSITORY/.agents/skills"
    ;;
  claude)
    AGENT_FILE="$REPOSITORY/.claude/agents/implementer.md"
    [ -f "$AGENT_FILE" ] || die "Claude implementer設定が無い: .claude/agents/implementer.md"
    grep -Fxq 'name: implementer' "$AGENT_FILE" || die "Claude implementer名が不正"
    grep -Fxq 'model: claude-sonnet-5' "$AGENT_FILE" || die "Claude implementer modelが不正"
    grep -Fxq 'effort: max' "$AGENT_FILE" || die "Claude implementer effortが不正"
    SKILLS_ROOT="$REPOSITORY/.claude/skills"
    ;;
  *) die "agentはclaudeまたはcodexに限定する" ;;
esac

[ -x "$SKILLS_ROOT/tdd/implementer-read.sh" ] || die "安全なimplementer読み取りscriptが無い"
[ -x "$SKILLS_ROOT/polish/capture-scope.sh" ] || die "implementation scope scriptが無い"
echo "implementer-preflight: $1 ok"
