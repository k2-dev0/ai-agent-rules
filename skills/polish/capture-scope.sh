#!/bin/bash
# tdd が本体コードへ触る前にscopeを固定し、後から実変更pathだけを列挙する。
set -eu

FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"
ACTIVE_DIR="$RECEIPT_DIR/implementation.active"
ACTIVE_SCOPE="$ACTIVE_DIR/scope"
OWNER_FILE="$RECEIPT_DIR/implementation.owner"

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

validate_implementation_path() {
  case "$1" in
    *.test.*|*.spec.*|*_test.*|*_spec.*|test_*.*|spec_*.*|test/*|tests/*|__tests__/*|*/test/*|*/tests/*|*/__tests__/*|*.snap|*fixture*|*mock*|*stub*|*fake*)
      die "test資産は実装subagentのscopeにできない: $1" ;;
    AGENTS.md|*/AGENTS.md|CLAUDE.md|*/CLAUDE.md|*.md|package.json|*/package.json|*lock*.json|*.lock|*.toml|*.yaml|*.yml|*.env|*.env.*|*/migrations/*|.git/*|*/.git/*|.claude/*|.codex/*|.agents/*)
      die "保護対象は実装subagentのscopeにできない: $1" ;;
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
}

if [ "${1:-}" = "activate" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh activate <機能名>"
  FEATURE=$2
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  read_scope_receipt
  REQUEST_RECEIPT="$RECEIPT_DIR/$FEATURE.implementation-request"
  [ -f "$REQUEST_RECEIPT" ] || die "検証済みimplementation requestが無い: $FEATURE"
  [ ! -e "$ACTIVE_DIR" ] || die "別の実装subagent scopeがactive: $(sed -n '2p' "$ACTIVE_SCOPE" 2>/dev/null || echo unknown)"

  PATH_COUNT=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    PATH_COUNT=$((PATH_COUNT + 1))
    validate_path "$path"
    validate_implementation_path "$path"
    [ -d "$REPOSITORY/$(dirname "$path")" ] || die "$path の親directoryが存在しない"
    [ ! -d "$REPOSITORY/$path" ] || die "scopeはdirectoryではなく個別fileに限定する: $path"
    [ ! -L "$REPOSITORY/$path" ] || die "$path はsymlinkなのでscopeにできない"
    if ! git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 && git check-ignore -q -- "$path"; then
      die "$path はignoredされている"
    fi
    [ -z "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ] || die "$path に実装前の変更がある"
  done < <(sed -n '3,$p' "$SCOPE_RECEIPT")
  [ "$PATH_COUNT" -gt 0 ] || die "実装subagentの許可pathが空"

  mkdir -p "$RECEIPT_DIR" || die "scope receipt用の一時ディレクトリを作れない"
  mkdir "$ACTIVE_DIR" 2>/dev/null || die "別の実装subagent scopeがactive"
  if ! {
    printf '%s\n%s\n%s\n' "$REPOSITORY" "$FEATURE" "$BASE"
    sed -n '3,$p' "$SCOPE_RECEIPT"
  } > "$ACTIVE_SCOPE"; then
    rmdir "$ACTIVE_DIR" 2>/dev/null || true
    die "実装subagentのactive scopeを作れない"
  fi
  if ! mv "$REQUEST_RECEIPT" "$ACTIVE_DIR/request.json"; then
    rm -f "$ACTIVE_SCOPE"
    rmdir "$ACTIVE_DIR" 2>/dev/null || true
    die "検証済みimplementation requestをactive scopeへ移せない"
  fi
  echo "activated: $FEATURE"
  exit 0
fi

if [ "${1:-}" = "deactivate" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh deactivate <機能名>"
  FEATURE=$2
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  [ -f "$ACTIVE_SCOPE" ] || die "activeな実装subagent scopeが無い"
  [ "$(sed -n '1p' "$ACTIVE_SCOPE")" = "$REPOSITORY" ] || die "active scopeのリポジトリが一致しない"
  [ "$(sed -n '2p' "$ACTIVE_SCOPE")" = "$FEATURE" ] || die "active scopeの機能名が一致しない"
  rm -f "$ACTIVE_DIR/request.json"
  rm "$ACTIVE_SCOPE" || die "active scopeを解除できない"
  rmdir "$ACTIVE_DIR" || die "active scope directoryを解除できない"
  rm -f "$OWNER_FILE"
  echo "deactivated: $FEATURE"
  exit 0
fi

if [ "${1:-}" = "list-changed" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh list-changed <機能名>"
  FEATURE=$2
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  read_scope_receipt
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
rm -f "$RECEIPT_DIR/$FEATURE.implementation-request"
BASE=$(git rev-parse HEAD)
mkdir -p "$RECEIPT_DIR" || die "scope receipt用の一時ディレクトリを作れない"
TEMP_SCOPE="$SCOPE_RECEIPT.tmp.$$"
printf '%s\n%s\n' "$REPOSITORY" "$BASE" > "$TEMP_SCOPE" || die "scope receiptを作れない"

for path in "$@"; do
  validate_path "$path"
  validate_implementation_path "$path"
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
