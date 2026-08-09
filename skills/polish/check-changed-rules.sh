#!/bin/bash
# 基準commitから追加・置換された行だけへ、共通のコード規約を適用する。
set -eu

FEATURE="${1:-}"
FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

[ "$#" -ge 3 ] && [ "$2" = "--" ] || die "usage: check-changed-rules.sh <機能名> -- <相対path>..."
[[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
command -v jq >/dev/null 2>&1 || die "ESLintの結果検査にjqが必要"
shift 2
INPUT_PATHS=("$@")

REPOSITORY=$(git rev-parse --show-toplevel)
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
SCOPE_RECEIPT="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY/$FEATURE.scope"
RULES_RECEIPT="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY/$FEATURE.rules"
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

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/polish-changed-rules.XXXXXX") || die "一時ディレクトリを作れない"
CHANGED_LINES="$TEMP_DIR/changed-lines.tsv"
FAILURES="$TEMP_DIR/failures.txt"
trap 'rm -rf "$TEMP_DIR"' EXIT
: > "$CHANGED_LINES"
: > "$FAILURES"

validate_path() {
  case "$1" in
    ""|.|/*|../*|*/../*|*/..|*"$(printf '\t')"*|*[*?\[\]:]*) die "不正な個別file path: $1" ;;
  esac
  case "$1" in
    *$'\n'*|*$'\r'*) die "改行を含むpathは扱えない" ;;
  esac
}

append_changed_lines() {
  local path=$1
  git diff --unified=0 --no-ext-diff "$BASE" -- ":(literal)$path" |
    awk -v path="$path" '
      /^@@ / {
        header = $0
        sub(/^.*\+/, "", header)
        sub(/ .*/, "", header)
        split(header, range, ",")
        current = range[1] + 0
        in_hunk = 1
        next
      }
      in_hunk && /^\+/ && !/^\+\+\+/ {
        printf "%s\t%d\t%s\n", path, current, substr($0, 2)
        current++
        next
      }
      in_hunk && /^-/ && !/^---/ { next }
      in_hunk && /^\\ No newline/ { next }
      in_hunk && !/^(diff --git |index |--- |\+\+\+ |@@ )/ { current++ }
    ' >> "$CHANGED_LINES"
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
  append_changed_lines "$path"
done

if [ ! -s "$CHANGED_LINES" ]; then
  HEAD=$(git rev-parse HEAD)
  printf '%s\n%s\n%s\n' "$REPOSITORY" "$HEAD" "$BASE" > "$RULES_RECEIPT" || die "変更行規約receiptを記録できない"
  echo "changed-rules: 追加行なし"
  exit 0
fi

find_eslint() {
  local target=$1
  local directory
  directory=$(dirname "$REPOSITORY/$target")
  while :; do
    if [ -x "$directory/node_modules/.bin/eslint" ]; then
      printf '%s\n' "$directory/node_modules/.bin/eslint"
      return 0
    fi
    [ "$directory" = "$REPOSITORY" ] && return 1
    [ "$directory" = "/" ] && return 1
    directory=$(dirname "$directory")
  done
}

find_package_root() {
  local target=$1
  local directory
  directory=$(dirname "$REPOSITORY/$target")
  while :; do
    if [ -f "$directory/package.json" ]; then
      printf '%s\n' "$directory"
      return 0
    fi
    [ "$directory" = "$REPOSITORY" ] && { printf '%s\n' "$REPOSITORY"; return 0; }
    [ "$directory" = "/" ] && { printf '%s\n' "$REPOSITORY"; return 0; }
    directory=$(dirname "$directory")
  done
}

check_code_rules() {
  local path=$1
  local eslint_path package_root json_file lines_file diagnostics_file restricted_syntax_rule status line message
  lines_file="$TEMP_DIR/lines.$$.txt"
  awk -F '\t' -v target="$path" '$1 == target { print $2 }' "$CHANGED_LINES" > "$lines_file"
  [ -s "$lines_file" ] || return 0
  [ -f "$REPOSITORY/$path" ] || return 0

  eslint_path=$(find_eslint "$path") || die "$path: ESLintが見つからず、追加行のマジックナンバーを検査できない"
  package_root=$(find_package_root "$path")
  json_file="$TEMP_DIR/eslint.$$.json"
  diagnostics_file="$TEMP_DIR/eslint-diagnostics.$$.tsv"
  restricted_syntax_rule='no-restricted-syntax:["error",{"selector":":matches(ImportDeclaration, ExportNamedDeclaration, ExportAllDeclaration, ImportExpression, CallExpression[callee.name=\"require\"], TSExternalModuleReference) > :matches(Literal, StringLiteral)[value=/^\\.\\.\\x2f\\.\\.(?:\\x2f|$)/]","message":"2階層以上の相対importは禁止。path aliasを使うこと"}]'

  set +e
  (cd "$package_root" && "$eslint_path" --no-ignore --format json --rule 'no-magic-numbers:error' --rule "$restricted_syntax_rule" "$REPOSITORY/$path") > "$json_file" 2>/dev/null
  status=$?
  set -e
  [ "$status" -le 1 ] || die "$path: ESLintによる共通規約検査を実行できない"
  jq -e . "$json_file" >/dev/null 2>&1 || die "$path: ESLintのJSON結果を読めない"
  jq -e 'length > 0 and all(.[]; all(.messages[]; (.fatal != true) and (((.ruleId == null) and (.message | test("ignored|matching configuration"; "i"))) | not)))' "$json_file" >/dev/null 2>&1 || die "$path: ESLintの構文解析または設定に失敗した"
  jq -r '.[] | .messages[] | select(.ruleId == "no-magic-numbers" or .ruleId == "no-restricted-syntax") | [.line, .message] | @tsv' "$json_file" > "$diagnostics_file"

  while IFS="$(printf '\t')" read -r line message; do
    [ -n "$line" ] || continue
    if grep -Fxq "$line" "$lines_file"; then
      printf '%s:%s: %s\n' "$path" "$line" "$message" >> "$FAILURES"
    fi
  done < "$diagnostics_file"
}

for path in "${PATHS[@]}"; do
  case "$path" in
    *.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx|*.mts|*.cts) check_code_rules "$path" ;;
  esac
done

if [ -s "$FAILURES" ]; then
  cat "$FAILURES" >&2
  exit 1
fi

HEAD=$(git rev-parse HEAD)
printf '%s\n%s\n%s\n' "$REPOSITORY" "$HEAD" "$BASE" > "$RULES_RECEIPT" || die "変更行規約receiptを記録できない"
echo "changed-rules: 追加行のみ検査済み"
