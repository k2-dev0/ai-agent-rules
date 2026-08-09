#!/bin/bash
# tdd が本体コードへ触る前に、polishの差分基準と対象pathだけを固定する。
set -eu

FEATURE="${1:-}"
FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -ge 3 ] && [ "$2" = "--" ] || die "usage: capture-scope.sh <機能名> -- <相対path>..."
[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
shift 2

REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"
SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"
QUALITY_RECEIPT="$RECEIPT_DIR/$FEATURE"
BASE=$(git rev-parse HEAD)
mkdir -p "$RECEIPT_DIR" || die "scope receipt用の一時ディレクトリを作れない"
TEMP_SCOPE="$SCOPE_RECEIPT.tmp.$$"
printf '%s\n%s\n' "$REPOSITORY" "$BASE" > "$TEMP_SCOPE" || die "scope receiptを作れない"

for path in "$@"; do
  case "$path" in
    ""|.|/*|../*|*/../*|*/..|*"$(printf '\t')"*|*[*?\[\]:]*) die "不正な個別file path: $path" ;;
  esac
  case "$path" in
    *$'\n'*|*$'\r'*) die "改行を含むpathは扱えない" ;;
  esac
  [ -d "$REPOSITORY/$(dirname "$path")" ] || die "$path の親directoryが存在しない"
  [ ! -d "$REPOSITORY/$path" ] || die "scopeはdirectoryではなく個別fileに限定する: $path"
  if ! git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 && git check-ignore -q -- "$path"; then
    die "$path はignoredされている"
  fi
  [ -z "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ] || die "$path に開始前の変更がある"
  printf '%s\n' "$path" >> "$TEMP_SCOPE" || die "対象pathをscope receiptへ記録できない"
done

mv "$TEMP_SCOPE" "$SCOPE_RECEIPT" || die "scope receiptを記録できない"
rm -f "$QUALITY_RECEIPT"
echo "captured: $FEATURE $BASE"
