#!/bin/bash
# tdd が本体コードへ触る前にscopeを固定し、後から実変更pathだけを列挙する。
set -eu

FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"

validate_path() {
  case "$1" in
    ""|.|/*|../*|*/../*|*/..|*"$(printf '\t')"*|*[*?\[\]:]*) die "不正な個別file path: $1" ;;
  esac
  case "$1" in
    *$'\n'*|*$'\r'*) die "改行を含むpathは扱えない" ;;
  esac
}

if [ "${1:-}" = "list-changed" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh list-changed <機能名>"
  FEATURE=$2
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"
  [ -f "$SCOPE_RECEIPT" ] || die "polish対象の開始receiptが無い: $FEATURE"
  EXPECTED_REPOSITORY=$(sed -n '1p' "$SCOPE_RECEIPT")
  BASE=$(sed -n '2p' "$SCOPE_RECEIPT")
  [ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || die "開始receiptのリポジトリが一致しない"
  git cat-file -e "$BASE^{commit}" >/dev/null 2>&1 || die "開始commitが存在しない: $BASE"
  git merge-base --is-ancestor "$BASE" HEAD || die "開始commitが現在HEADの祖先ではない"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    validate_path "$path"
    if git diff --quiet --no-ext-diff "$BASE" HEAD -- ":(literal)$path"; then
      continue
    else
      STATUS=$?
      [ "$STATUS" -eq 1 ] || die "$path の差分を判定できない"
    fi
    if [ -e "$REPOSITORY/$path" ] || [ -L "$REPOSITORY/$path" ]; then
      [ ! -L "$REPOSITORY/$path" ] || die "$path はsymlinkなので実変更対象にできない"
      git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 || die "$path は未追跡またはignoredのまま"
      printf '%s\n' "$path"
    fi
  done < <(sed -n '3,$p' "$SCOPE_RECEIPT")
  exit 0
fi

FEATURE="${1:-}"
[ "$#" -ge 3 ] && [ "$2" = "--" ] || die "usage: capture-scope.sh <機能名> -- <相対path>..."
[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
shift 2

SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"
QUALITY_RECEIPT="$RECEIPT_DIR/$FEATURE"
BASE=$(git rev-parse HEAD)
mkdir -p "$RECEIPT_DIR" || die "scope receipt用の一時ディレクトリを作れない"
TEMP_SCOPE="$SCOPE_RECEIPT.tmp.$$"
printf '%s\n%s\n' "$REPOSITORY" "$BASE" > "$TEMP_SCOPE" || die "scope receiptを作れない"

for path in "$@"; do
  validate_path "$path"
  [ -d "$REPOSITORY/$(dirname "$path")" ] || die "$path の親directoryが存在しない"
  [ ! -d "$REPOSITORY/$path" ] || die "scopeはdirectoryではなく個別fileに限定する: $path"
  [ ! -L "$REPOSITORY/$path" ] || die "$path はsymlinkなのでscopeにできない"
  if ! git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 && git check-ignore -q -- "$path"; then
    die "$path はignoredされている"
  fi
  [ -z "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ] || die "$path に開始前の変更がある"
  printf '%s\n' "$path" >> "$TEMP_SCOPE" || die "対象pathをscope receiptへ記録できない"
done

mv "$TEMP_SCOPE" "$SCOPE_RECEIPT" || die "scope receiptを記録できない"
rm -f "$QUALITY_RECEIPT"
echo "captured: $FEATURE $BASE"
