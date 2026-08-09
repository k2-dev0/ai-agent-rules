#!/bin/bash
# mark-prompt-done: tdd from-prompt が実装を終えた設計書を、.[agent_name]/prompt/.prompt.md の
# 実装順リスト上で [ ] から [x] へ倒す。
# .[agent_name]/ は sandbox の denyWrite で保護されておりエージェントは直接書き込めないため、
# 進捗の記録もこの固定処理へ閉じ込める。本スクリプトにできるのは「対象 1 行のチェックボックスを
# [ ] から [x] にする」ことだけで、任意の内容の書き込みもファイルの削除もできない。
# 使い方: bash mark-prompt-done.sh <機能名>   例) bash mark-prompt-done.sh user-address
# 失敗の扱い: 対象が無い・既に [x] は exit 1（握りつぶし禁止）。実装済みの取り違えを黙って通さない。
set -u

NAME="${1:?usage: mark-prompt-done.sh <機能名>}"
INDEX=".[agent_name]/prompt/.prompt.md"
# 機能名の文字集合は apply-prompt.sh と同一（ASCII kebab-case）。
NAME_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die(){ echo "ERROR: $1" >&2; exit 1; }

[[ "$NAME" =~ $NAME_RE ]] || die "invalid 機能名: $NAME (ASCII kebab-case only)"
ENTRY="branch-$NAME-prompt.md"

[ -L "$INDEX" ] && die "index is a symlink: $INDEX"
[ -f "$INDEX" ] || die "index not found: $INDEX"

ESC=$(printf '%s' "$ENTRY" | sed 's/\./\\./g')
grep -qE "^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]+$ESC[[:space:]]*$" "$INDEX" \
  || die "entry not found in index: $ENTRY"
grep -qE "^[[:space:]]*-[[:space:]]*\[ \][[:space:]]+$ESC[[:space:]]*$" "$INDEX" \
  || die "already marked as done: $ENTRY"

TMP=$(mktemp "${TMPDIR:-/tmp}/mark-prompt-done.XXXXXX") || die "cannot create temp file"
trap 'rm -f "$TMP"' EXIT

awk -v entry="$ENTRY" '
  {
    line = $0
    if (!flipped && match(line, /^[[:space:]]*-[[:space:]]*\[ \][[:space:]]+/)) {
      rest = substr(line, RSTART + RLENGTH)
      sub(/[[:space:]]+$/, "", rest)
      if (rest == entry) { sub(/\[ \]/, "[x]", line); flipped = 1 }
    }
    print line
  }
  END { exit(flipped ? 0 : 1) }
' "$INDEX" > "$TMP" || die "failed to mark: $ENTRY"

cp -- "$TMP" "$INDEX" || die "copy failed: $INDEX"
echo "done: $ENTRY"

REMAIN=$(grep -cE '^[[:space:]]*-[[:space:]]*\[ \][[:space:]]+branch-' "$INDEX")
echo "remaining: $REMAIN"
