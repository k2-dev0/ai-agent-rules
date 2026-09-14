#!/bin/bash
# 専用子の開始時に共通制約とrole契約を渡す。親の手順は起動前に正本を読む。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
[ "$(hook_event_name)" = SubagentStart ] || exit 0
CWD=$(hook_cwd)
[ -n "$CWD" ] || CWD=$PWD
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || {
  hook_review_context "repository rootを確認できないため契約を注入できません。成功扱いせず失敗を返してください。"
  exit 0
}

skill_file() {
  local relative=$1 base
  case "$HOOK_AGENT" in
    codex) base="$ROOT/.agents/skills" ;;
    claude) base="$ROOT/.claude/skills" ;;
  esac
  [ -f "$base/$relative" ] && [ -r "$base/$relative" ] || return 1
  printf '%s\n' "$base/$relative"
}

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
COMMON=$(skill_file CHILD_RULES.md) || {
  hook_review_context "子の共通制約が見つかりません。成功扱いせず失敗を返してください。"
  exit 0
}
hook_review_context "契約の相対参照は $(dirname "$FILE") を基準に解決してください。
共通制約と専用契約は全文を確認してから作業してください。省略・退避された場合は示された保存先を読み、全文を確認できなければ契約未確認として失敗を返してください。

$(cat "$COMMON")

$(cat "$FILE")"
exit 0
