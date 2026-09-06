#!/bin/bash
# polish のverified入力は実変更pathとの一致を、direct入力は明示pathの安全性だけを検査する。
set -eu

FEATURE="${1:-}"
FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
MODE="verified"
case "${2:-}" in
  --)
    shift 2
    ;;
  --direct-check)
    [ "${3:-}" = "--" ] || die "usage: quality-gate.sh <機能名> --direct-check -- <明示path>..."
    MODE="direct-check"
    shift 3
    ;;
  --direct)
    [ "${3:-}" = "--" ] || die "usage: quality-gate.sh <機能名> --direct -- <明示path>..."
    MODE="direct"
    shift 3
    ;;
  *) die "usage: quality-gate.sh <機能名> [--direct-check|--direct] -- <path>..." ;;
esac
INPUT_PATHS=("$@")

REPOSITORY=$(git rev-parse --show-toplevel)
validate_direct_input() {
  local path seen_paths cursor
  [ "${#INPUT_PATHS[@]}" -gt 0 ] || die "direct modeには明示pathが必要"
  seen_paths=$'\n'
  for path in "${INPUT_PATHS[@]}"; do
    case "$path" in
      ""|.|/*|../*|*/../*|*/..|*"$(printf '\t')"*) die "不正な個別file path: $path" ;;
      *'*'*|*'?'*|*':'*) die "不正な個別file path: $path" ;;
      ./*|*/./*|*//*) die "正規化された相対pathを指定すること: $path" ;;
      *$'\n'*|*$'\r'*) die "改行を含むpathは扱えない" ;;
    esac
    case "$seen_paths" in
      *$'\n'"$path"$'\n'*) die "direct modeの明示pathが重複している: $path" ;;
    esac
    seen_paths="${seen_paths}${path}"$'\n'
    [ -f "$REPOSITORY/$path" ] || die "$path は通常fileではない、または存在しない"
    [ ! -L "$REPOSITORY/$path" ] || die "$path はsymlinkなのでdirect modeの対象にできない"
    cursor=$(dirname "$path")
    while [ "$cursor" != "." ]; do
      [ ! -L "$REPOSITORY/$cursor" ] || die "$path の親directoryがsymlink"
      cursor=$(dirname "$cursor")
    done
    if ! git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 && git check-ignore -q -- "$path"; then
      die "$path はignoredされている"
    fi
  done
}

require_input_clean() {
  local path
  [ "${#INPUT_PATHS[@]}" -gt 0 ] || return 0
  for path in "${INPUT_PATHS[@]}"; do
    git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 || die "$path は未追跡またはignoredのまま"
    [ -z "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ] || die "$path に未コミット変更がある"
  done
}

if [ "$MODE" != "verified" ]; then
  validate_direct_input
  if [ "$MODE" = "direct-check" ]; then
    echo "validated-direct: $FEATURE scope-unverified"
    exit 0
  fi
  require_input_clean
  echo "checked-direct: $FEATURE scope-unverified"
  exit 0
fi

# baselineと実変更pathの判定は列挙側を正本にし、失敗時の部分出力は採用しない。
CHANGED_OUTPUT=$(bash "$(dirname "$0")/capture-scope.sh" list-changed "$FEATURE") || exit $?
CHANGED_PATHS=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  CHANGED_PATHS+=("$path")
done <<< "$CHANGED_OUTPUT"

[ "${#INPUT_PATHS[@]}" -eq "${#CHANGED_PATHS[@]}" ] || die "quality gate入力pathが実際に変更されたfileと一致しない"
for ((index = 0; index < ${#CHANGED_PATHS[@]}; index++)); do
  [ "${INPUT_PATHS[$index]}" = "${CHANGED_PATHS[$index]}" ] || die "quality gate入力pathが実際に変更されたfileと一致しない"
done
require_input_clean
echo "checked: $FEATURE"
