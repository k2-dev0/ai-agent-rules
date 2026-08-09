#!/bin/bash
# polish の実変更pathを検査し、完了後のHEADとpath一覧を記録・再検証する。
# receipt は一時領域に置き、設計書の index や作業ツリーを汚さない。
set -eu

MODE="${1:-}"
FEATURE="${2:-}"
FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

case "$MODE" in
  check|record)
    [ "$#" -ge 3 ] && [ "$3" = "--" ] || die "usage: quality-gate.sh $MODE <機能名> -- <実変更path>..."
    shift 3
    INPUT_PATHS=("$@")
    ;;
  verify)
    [ "$#" -eq 2 ] || die "usage: quality-gate.sh verify <機能名>"
    INPUT_PATHS=()
    ;;
  *) die "mode は check、record、verify に限定する" ;;
esac
[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"

REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"
RECEIPT="$RECEIPT_DIR/$FEATURE"
SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"

load_scope() {
  [ -f "$SCOPE_RECEIPT" ] || die "polish対象の開始receiptが無い: $FEATURE"
  EXPECTED_REPOSITORY=$(sed -n '1p' "$SCOPE_RECEIPT")
  BASE=$(sed -n '2p' "$SCOPE_RECEIPT")
  [ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || die "開始receiptのリポジトリが一致しない"
  git cat-file -e "$BASE^{commit}" >/dev/null 2>&1 || die "開始commitが存在しない: $BASE"
  git merge-base --is-ancestor "$BASE" HEAD || die "開始commitが現在HEADの祖先ではない"
  PATHS=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    PATHS+=("$path")
  done < <(sed -n '3,$p' "$SCOPE_RECEIPT")
  [ "${#PATHS[@]}" -gt 0 ] || die "開始receiptに対象pathが無い"
}

require_scope_clean() {
  local path
  for path in "${PATHS[@]}"; do
    if [ -e "$REPOSITORY/$path" ] || [ -L "$REPOSITORY/$path" ]; then
      git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 || die "$path は未追跡またはignoredのまま"
    else
      if git ls-tree -r --name-only "$BASE" -- ":(literal)$path" | grep -Fxq "$path"; then
        : # commit済み削除
      elif ! git diff --quiet --no-ext-diff "$BASE" HEAD -- ":(literal)$path"; then
        die "$path は追跡済みfileでも未使用の新規候補でもない"
      fi
    fi
    [ -z "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ] || die "$path に未コミット変更がある"
  done
}

load_changed_paths() {
  local path status
  CHANGED_PATHS=()
  for path in "${PATHS[@]}"; do
    if git diff --quiet --no-ext-diff "$BASE" HEAD -- ":(literal)$path"; then
      continue
    else
      status=$?
      [ "$status" -eq 1 ] || die "$path の差分を判定できない"
    fi
    if [ -e "$REPOSITORY/$path" ] || [ -L "$REPOSITORY/$path" ]; then
      CHANGED_PATHS+=("$path")
    fi
  done
}

require_changed_input() {
  local index
  [ "${#INPUT_PATHS[@]}" -eq "${#CHANGED_PATHS[@]}" ] || die "quality gate入力pathが実際に変更されたfileと一致しない"
  for ((index = 0; index < ${#CHANGED_PATHS[@]}; index++)); do
    [ "${INPUT_PATHS[$index]}" = "${CHANGED_PATHS[$index]}" ] || die "quality gate入力pathが実際に変更されたfileと一致しない"
  done
}

verify_recorded_paths() {
  local index
  RECORDED_PATHS=()
  while IFS= read -r path; do
    [ -n "$path" ] && RECORDED_PATHS+=("$path")
  done < <(sed -n '4,$p' "$RECEIPT")
  [ "${#RECORDED_PATHS[@]}" -eq "${#CHANGED_PATHS[@]}" ] || die "polish後に実変更pathが変わった"
  for ((index = 0; index < ${#CHANGED_PATHS[@]}; index++)); do
    [ "${RECORDED_PATHS[$index]}" = "${CHANGED_PATHS[$index]}" ] || die "polish後に実変更pathが変わった"
  done
}

case "$MODE" in
  check|record)
    load_scope
    require_scope_clean
    load_changed_paths
    require_changed_input
    if [ "$MODE" = "record" ]; then
      mkdir -p "$RECEIPT_DIR" || die "quality gate receipt用の一時ディレクトリを作れない"
      HEAD=$(git rev-parse HEAD)
      printf '%s\n%s\n%s\n' "$REPOSITORY" "$HEAD" "$BASE" > "$RECEIPT" || die "quality gate receiptを記録できない"
      if [ "${#CHANGED_PATHS[@]}" -gt 0 ]; then
        printf '%s\n' "${CHANGED_PATHS[@]}" >> "$RECEIPT" || die "実変更pathをquality receiptへ記録できない"
      fi
      echo "recorded: $FEATURE $HEAD"
    else
      echo "checked: $FEATURE"
    fi
    ;;
  verify)
    [ -f "$RECEIPT" ] || die "polish品質ゲートのreceiptが無い: $FEATURE"
    EXPECTED_REPOSITORY=$(sed -n '1p' "$RECEIPT")
    EXPECTED_HEAD=$(sed -n '2p' "$RECEIPT")
    [ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || die "quality gate receiptのリポジトリが一致しない"
    [ "$EXPECTED_HEAD" = "$(git rev-parse HEAD)" ] || die "polish後にHEADが変わった。品質ゲートを再実行して記録し直すこと"
    load_scope
    require_scope_clean
    load_changed_paths
    verify_recorded_paths
    ;;
esac
