#!/bin/bash
# polish の入力が実変更pathと一致し、追跡済み・cleanであることだけを検査する。
set -eu

FEATURE="${1:-}"
FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -ge 2 ] && [ "$2" = "--" ] || die "usage: quality-gate.sh <機能名> -- <実変更path>..."
[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
shift 2
INPUT_PATHS=("$@")

REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
RECEIPT_DIR="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY"
SCOPE_RECEIPT="$RECEIPT_DIR/$FEATURE.scope"

load_scope() {
  [ -f "$SCOPE_RECEIPT" ] || die "polish対象の開始receiptが無い: $FEATURE"
  EXPECTED_REPOSITORY=$(sed -n '1p' "$SCOPE_RECEIPT")
  BASE=$(sed -n '2p' "$SCOPE_RECEIPT")
  [ "$EXPECTED_REPOSITORY" = "$REPOSITORY" ] || die "開始receiptのリポジトリが一致しない"
  git cat-file -e "$BASE^{commit}" >/dev/null 2>&1 || die "開始commitが存在しない: $BASE"
  git merge-base --is-ancestor "$BASE" HEAD || die "開始commitが現在HEADの祖先ではない"
  AUTO_SCOPE=false
  if [ "$(sed -n '3p' "$SCOPE_RECEIPT")" = "@auto" ]; then
    AUTO_SCOPE=true
    PATHS=()
    return
  fi
  PATHS=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    PATHS+=("$path")
  done < <(sed -n '3,$p' "$SCOPE_RECEIPT")
  [ "${#PATHS[@]}" -gt 0 ] || die "開始receiptに対象pathが無い"
}

require_input_clean() {
  local path
  [ "${#INPUT_PATHS[@]}" -gt 0 ] || return 0
  for path in "${INPUT_PATHS[@]}"; do
    git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 || die "$path は未追跡またはignoredのまま"
    [ -z "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ] || die "$path に未コミット変更がある"
  done
}

load_changed_paths() {
  local path status
  CHANGED_PATHS=()
  if [ "$AUTO_SCOPE" = true ]; then
    while IFS= read -r -d '' path; do
      if [ -e "$REPOSITORY/$path" ] || [ -L "$REPOSITORY/$path" ]; then
        CHANGED_PATHS+=("$path")
      fi
    done < <(git diff --name-only -z --diff-filter=ACMRTUXB "$BASE" HEAD)
    return
  fi
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

load_scope
load_changed_paths
require_changed_input
require_input_clean
echo "checked: $FEATURE"
