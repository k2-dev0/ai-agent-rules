#!/bin/bash
# polish 完了後のHEADを記録・検証する。
# receipt は一時領域に置き、設計書の index や作業ツリーを汚さない。
set -eu

MODE="${1:-}"
FEATURE="${2:-}"
FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -eq 2 ] || die "usage: quality-gate.sh <record|verify> <機能名>"
[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"

REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"
RECEIPT="$RECEIPT_DIR/$FEATURE"
SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"
PATHS_RECEIPT="$RECEIPT_DIR/$FEATURE.paths"

load_scope() {
  [ -f "$SCOPE_RECEIPT" ] || die "polish対象の開始receiptが無い: $FEATURE"
  EXPECTED_REPOSITORY=$(sed -n '1p' "$SCOPE_RECEIPT")
  BASE=$(sed -n '2p' "$SCOPE_RECEIPT")
  [ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || die "開始receiptのリポジトリが一致しない"
  git cat-file -e "$BASE^{commit}" >/dev/null 2>&1 || die "開始commitが存在しない: $BASE"
  git merge-base --is-ancestor "$BASE" HEAD || die "開始commitが現在HEADの祖先ではない"
  PATHS=()
  while IFS= read -r path; do
    [ -n "$path" ] && PATHS+=("$path")
  done < <(sed -n '3,$p' "$SCOPE_RECEIPT")
  [ "${#PATHS[@]}" -gt 0 ] || die "開始receiptに対象pathが無い"
}

require_scope_clean() {
  local path
  for path in "${PATHS[@]}"; do
    [ ! -d "$REPOSITORY/$path" ] || die "scopeはdirectoryではなく個別fileに限定する: $path"
    if [ -e "$REPOSITORY/$path" ] || [ -L "$REPOSITORY/$path" ]; then
      git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 || die "$path は未追跡またはignoredのまま"
    else
      git ls-tree -r --name-only "$BASE" -- ":(literal)$path" | grep -Fxq "$path" || die "$path は追跡済みfileでもcommit済み削除でもない"
    fi
    [ -z "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ] || die "$path に未コミット変更がある"
  done
}

verify_paths_receipt() {
  [ -f "$PATHS_RECEIPT" ] || die "polish scope path receiptが無い: $FEATURE"
  PATHS_REPOSITORY=$(sed -n '1p' "$PATHS_RECEIPT")
  PATHS_HEAD=$(sed -n '2p' "$PATHS_RECEIPT")
  PATHS_BASE=$(sed -n '3p' "$PATHS_RECEIPT")
  [ "$PATHS_REPOSITORY" = "$REPOSITORY" ] || die "scope path receiptのリポジトリが一致しない"
  [ "$PATHS_HEAD" = "$(git rev-parse HEAD)" ] || die "scope path検査後にHEADが変わった"
  [ "$PATHS_BASE" = "$BASE" ] || die "scope path receiptの開始commitが一致しない"
}

case "$MODE" in
  record)
    load_scope
    require_scope_clean
    verify_paths_receipt
    mkdir -p "$RECEIPT_DIR" || die "quality gate receipt用の一時ディレクトリを作れない"
    HEAD=$(git rev-parse HEAD)
    printf '%s\n%s\n%s\n' "$REPOSITORY" "$HEAD" "$BASE" > "$RECEIPT" || die "quality gate receiptを記録できない"
    echo "recorded: $FEATURE $HEAD"
    ;;
  verify)
    [ -f "$RECEIPT" ] || die "polish品質ゲートのreceiptが無い: $FEATURE"
    EXPECTED_REPOSITORY=$(sed -n '1p' "$RECEIPT")
    EXPECTED_HEAD=$(sed -n '2p' "$RECEIPT")
    [ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || die "quality gate receiptのリポジトリが一致しない"
    [ "$EXPECTED_HEAD" = "$(git rev-parse HEAD)" ] || die "polish後にHEADが変わった。品質ゲートを再実行して記録し直すこと"
    load_scope
    require_scope_clean
    ;;
  *)
    die "mode は record または verify に限定する"
    ;;
esac
