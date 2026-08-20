#!/bin/bash
# active implementation requestに列挙された入力だけを、実装者と親へ読み出す。
set -eu

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: implementer-read.sh <相対path>"
command -v jq >/dev/null 2>&1 || die "jq が必要"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"

REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
ACTIVE_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY/implementation.active"
ACTIVE_REQUEST="$ACTIVE_DIR/request.json"
ACTIVE_MODE="$ACTIVE_DIR/mode"
PATH_TO_READ=$1

[ -f "$ACTIVE_REQUEST" ] || die "activeなimplementation requestが無い"
[ -f "$ACTIVE_MODE" ] || die "activeな実装scopeのmodeが無い"
case "$(sed -n '1p' "$ACTIVE_MODE")" in subagent|parent-fallback) ;; *) die "activeな実装scopeのmodeが不正" ;; esac

case "$PATH_TO_READ" in
  ""|.|/*|./*|../*|*/../*|*/..|*//*|*':'*|*'?'*|*'*'*|*$'\n'*|*$'\r'*|*$'\t'*)
    die "不正な読み取りpath: $PATH_TO_READ" ;;
esac

CURSOR="$REPOSITORY"
IFS='/' read -r -a SEGMENTS <<< "$PATH_TO_READ"
for SEGMENT in "${SEGMENTS[@]}"; do
  CURSOR="$CURSOR/$SEGMENT"
  [ ! -L "$CURSOR" ] || die "symlinkは読めない: $PATH_TO_READ"
done
[ -f "$REPOSITORY/$PATH_TO_READ" ] || die "読み取り対象fileが無い: $PATH_TO_READ"

ALLOWED=false
jq -e --arg path "$PATH_TO_READ" '
  (.spec == $path)
  or ((.allowed_paths // []) | index($path) != null)
  or ((.test_paths // []) | index($path) != null)
  or ([.worker_tasks[] | .result, .report, .evidence] | index($path) != null)
' "$ACTIVE_REQUEST" >/dev/null 2>&1 && ALLOWED=true

case "$PATH_TO_READ" in
  AGENTS.md|*/AGENTS.md|CLAUDE.md|*/CLAUDE.md|\
  .codex/agents/implementer.toml|.claude/agents/implementer.md|\
  .codex/rules/*|.claude/rules/*)
    ALLOWED=true ;;
esac

[ "$ALLOWED" = true ] || die "implementation request外の読み取りpath: $PATH_TO_READ"
cat "$REPOSITORY/$PATH_TO_READ"
