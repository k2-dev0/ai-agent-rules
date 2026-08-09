#!/bin/bash
# 開始receiptに固定した対象pathと現在の追跡状態だけを検証する。
set -eu

FEATURE="${1:-}"
FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -ge 3 ] && [ "$2" = "--" ] || die "usage: check-changed-rules.sh <機能名> -- <相対path>..."
[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
shift 2
INPUT_PATHS=("$@")

REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
SCOPE_RECEIPT="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY/$FEATURE.scope"
PATHS_RECEIPT="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY/$FEATURE.paths"
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
[ "${#INPUT_PATHS[@]}" -eq "${#PATHS[@]}" ] || die "polish入力pathが開始scopeと一致しない"
for ((index = 0; index < ${#PATHS[@]}; index++)); do
  [ "${INPUT_PATHS[$index]}" = "${PATHS[$index]}" ] || die "polish入力pathが開始scopeと一致しない"
done

validate_path() {
  case "$1" in
    ""|.|/*|../*|*/../*|*/..|*"$(printf '\t')"*|*[*?\[\]:]*) die "不正な個別file path: $1" ;;
  esac
  case "$1" in
    *$'\n'*|*$'\r'*) die "改行を含むpathは扱えない" ;;
  esac
}

for path in "${PATHS[@]}"; do
  validate_path "$path"
  [ ! -d "$REPOSITORY/$path" ] || die "scopeはdirectoryではなく個別fileに限定する: $path"
  if [ -e "$REPOSITORY/$path" ] || [ -L "$REPOSITORY/$path" ]; then
    git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1 || die "$path は未追跡またはignoredのまま"
  else
    git ls-tree -r --name-only "$BASE" -- ":(literal)$path" | grep -Fxq "$path" || die "$path は追跡済みfileでもcommit済み削除でもない"
  fi
  [ -z "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ] || die "$path に未コミット変更がある"
done

HEAD=$(git rev-parse HEAD)
printf '%s\n%s\n%s\n' "$REPOSITORY" "$HEAD" "$BASE" > "$PATHS_RECEIPT" || die "scope path receiptを記録できない"
echo "scope-paths: 対象path・追跡状態・clean HEADを検査済み"
