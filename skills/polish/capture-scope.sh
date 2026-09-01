#!/bin/bash
# 実装前のHEADを記録し、後から実変更pathだけを列挙する。
set -eu

FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"

validate_path() {
  case "$1" in
    ""|.|/*|../*|*/../*|*/..|*"$(printf '\t')"*) die "不正な個別file path: $1" ;;
  esac
  # Git 呼び出しはすべて :(literal) でpathspec解釈を止める。角括弧は実在pathに使えるため、
  # wildcard・magic signatureになり得る文字だけを拒否する。
  case "$1" in
    *'*'*|*'?'*|*':'*) die "不正な個別file path: $1" ;;
  esac
  case "$1" in
    *$'\n'*|*$'\r'*) die "改行を含むpathは扱えない" ;;
  esac
}

validate_scope_path() {
  case "$1" in
    *.test.*|*.spec.*|*_test.*|*_spec.*|test_*.*|spec_*.*|test/*|tests/*|__tests__/*|*/test/*|*/tests/*|*/__tests__/*|*.snap|*fixture*|*mock*|*stub*|*fake*)
      die "test資産はpolishの開始scopeにできない: $1" ;;
    AGENTS.md|*/AGENTS.md|CLAUDE.md|*/CLAUDE.md|*.md|package.json|*/package.json|*lock*.json|*.lock|*.toml|*.yaml|*.yml|*.env|*.env.*|*/migrations/*|.git/*|*/.git/*|.claude/*|.codex/*|.agents/*)
      die "保護対象はpolishの開始scopeにできない: $1" ;;
  esac
}

read_scope_receipt() {
  SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"
  [ -f "$SCOPE_RECEIPT" ] || die "polish対象の開始receiptが無い: $FEATURE"
  EXPECTED_REPOSITORY=$(sed -n '1p' "$SCOPE_RECEIPT")
  BASE=$(sed -n '2p' "$SCOPE_RECEIPT")
  [ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || die "開始receiptのリポジトリが一致しない"
  git cat-file -e "$BASE^{commit}" >/dev/null 2>&1 || die "開始commitが存在しない: $BASE"
  git merge-base --is-ancestor "$BASE" HEAD || die "開始commitが現在HEADの祖先ではない"
  SCOPE_MODE=$(sed -n '3p' "$SCOPE_RECEIPT")
}


if [ "${1:-}" = "list-changed" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh list-changed <機能名>"
  FEATURE=$2
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  read_scope_receipt
  if [ "$SCOPE_MODE" = "@auto" ]; then
    while IFS= read -r -d '' path; do
      [ -n "$path" ] || continue
      validate_path "$path"
      if [ -e "$REPOSITORY/$path" ] || [ -L "$REPOSITORY/$path" ]; then
        [ ! -L "$REPOSITORY/$path" ] || die "$path はsymlinkなので実変更対象にできない"
        git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 || die "$path は未追跡またはignoredのまま"
        printf '%s\n' "$path"
      fi
    done < <(git diff --name-only -z --diff-filter=ACMRTUXB "$BASE" HEAD)
    exit 0
  fi
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

if [ "${2:-}" = "--auto" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh <機能名> --auto"
  FEATURE=$1
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"
  BASE=$(git rev-parse HEAD)
  mkdir -p "$RECEIPT_DIR" || die "scope receipt用の一時ディレクトリを作れない"
  TEMP_SCOPE="$SCOPE_RECEIPT.tmp.$$"
  printf '%s\n%s\n@auto\n' "$REPOSITORY" "$BASE" > "$TEMP_SCOPE" || die "auto scope receiptを作れない"
  mv "$TEMP_SCOPE" "$SCOPE_RECEIPT" || die "auto scope receiptを記録できない"
  echo "captured-auto: $FEATURE $BASE"
  exit 0
fi

FEATURE="${1:-}"
[ "$#" -ge 3 ] && [ "$2" = "--" ] || die "usage: capture-scope.sh <機能名> -- <相対path>..."
[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
shift 2

SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"
BASE=$(git rev-parse HEAD)
mkdir -p "$RECEIPT_DIR" || die "scope receipt用の一時ディレクトリを作れない"
TEMP_SCOPE="$SCOPE_RECEIPT.tmp.$$"
printf '%s\n%s\n' "$REPOSITORY" "$BASE" > "$TEMP_SCOPE" || die "scope receiptを作れない"

for path in "$@"; do
  validate_path "$path"
  validate_scope_path "$path"
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
echo "captured: $FEATURE $BASE"
