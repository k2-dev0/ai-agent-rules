#!/bin/bash
# tdd が本体コードへ触る前にscopeを固定し、後から実変更pathだけを列挙する。
set -eu

. "$(dirname "$0")/implementation-scope-state.sh"

FEATURE_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'

die() { echo "ERROR: $1" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
REPOSITORY=$(git rev-parse --show-toplevel)
implementation_scope_init "$REPOSITORY"
RECEIPT_DIR=$IMPLEMENTATION_RECEIPT_DIR
ACTIVE_DIR=$IMPLEMENTATION_ACTIVE_DIR
ACTIVE_SCOPE=$IMPLEMENTATION_ACTIVE_SCOPE
ACTIVE_MODE=$IMPLEMENTATION_ACTIVE_MODE
ACTIVE_REQUEST=$IMPLEMENTATION_ACTIVE_REQUEST
ACTIVE_LEASE=$IMPLEMENTATION_ACTIVE_LEASE
OWNER_FILE=$IMPLEMENTATION_OWNER_FILE
RECOVERY_OWNER_FILE=$IMPLEMENTATION_RECOVERY_OWNER_FILE

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

collect_active_dirty_paths() {
  DIRTY_PATHS='[]'
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    validate_path "$path"
    if [ -n "$(git status --porcelain --untracked-files=all -- ":(literal)$path")" ]; then
      DIRTY_PATHS=$(printf '%s' "$DIRTY_PATHS" | jq --arg path "$path" '. + [$path]') || die "変更pathをJSONへ変換できない"
    fi
  done < <(sed -n '4,$p' "$ACTIVE_SCOPE")
}

if [ "${1:-}" = "status" ]; then
  [ "$#" -eq 1 ] || die "usage: capture-scope.sh status"
  if [ ! -d "$ACTIVE_DIR" ]; then
    printf '{"active":false}\n'
    exit 0
  fi
  [ -f "$ACTIVE_SCOPE" ] || die "activeな実装scopeのscope markerが無い"
  [ -f "$ACTIVE_MODE" ] || die "activeな実装scopeのmode markerが無い"
  [ -f "$ACTIVE_REQUEST" ] || die "activeなimplementation requestが無い"
  [ "$(sed -n '1p' "$ACTIVE_SCOPE")" = "$REPOSITORY" ] || die "active scopeのリポジトリが一致しない"
  FEATURE=$(sed -n '2p' "$ACTIVE_SCOPE")
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "active scopeの機能名が不正"
  MODE=$(sed -n '1p' "$ACTIVE_MODE")
  case "$MODE" in subagent|parent-fallback|orphaned) ;; *) die "active scopeのmodeが不正" ;; esac
  LEASE_AGE=$(implementation_scope_lease_age) || die "active scopeのleaseを判定できない"
  STALE_SECONDS=$(implementation_scope_stale_seconds) || die "POLISH_SCOPE_STALE_SECONDSが0以上の整数ではない"
  STALE=false
  [ "$LEASE_AGE" -lt "$STALE_SECONDS" ] || STALE=true
  RECOVERABLE=$STALE
  [ "$MODE" != "orphaned" ] || RECOVERABLE=true
  collect_active_dirty_paths
  jq -n \
    --arg repository "$REPOSITORY" \
    --arg feature "$FEATURE" \
    --arg mode "$MODE" \
    --argjson lease_age_seconds "$LEASE_AGE" \
    --argjson stale "$STALE" \
    --argjson recoverable "$RECOVERABLE" \
    --argjson dirty_paths "$DIRTY_PATHS" \
    '{active:true,repository:$repository,feature:$feature,mode:$mode,lease_age_seconds:$lease_age_seconds,stale:$stale,recoverable:$recoverable,dirty_paths:$dirty_paths}'
  exit 0
fi

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
  if ! printf 'subagent\n' > "$ACTIVE_MODE"; then
    rm -f "$ACTIVE_SCOPE"
    rmdir "$ACTIVE_DIR" 2>/dev/null || true
    die "実装scopeのmodeを記録できない"
  fi
  if ! mv "$REQUEST_RECEIPT" "$ACTIVE_DIR/request.json"; then
    rm -f "$ACTIVE_MODE" "$ACTIVE_SCOPE"
    rmdir "$ACTIVE_DIR" 2>/dev/null || true
    die "検証済みimplementation requestをactive scopeへ移せない"
  fi
  if ! implementation_scope_touch_lease; then
    mv "$ACTIVE_REQUEST" "$REQUEST_RECEIPT" 2>/dev/null || true
    rm -f "$ACTIVE_MODE" "$ACTIVE_SCOPE" "$ACTIVE_LEASE"
    rmdir "$ACTIVE_DIR" 2>/dev/null || true
    die "実装scopeのleaseを記録できない"
  fi
  echo "activated: $FEATURE"
  exit 0
fi

if [ "${1:-}" = "handoff-to-parent" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh handoff-to-parent <機能名>"
  FEATURE=$2
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  [ -f "$ACTIVE_SCOPE" ] || die "activeな実装scopeが無い"
  [ -f "$ACTIVE_MODE" ] || die "activeな実装scopeのmodeが無い"
  [ -f "$ACTIVE_DIR/request.json" ] || die "activeなimplementation requestが無い"
  [ "$(sed -n '1p' "$ACTIVE_SCOPE")" = "$REPOSITORY" ] || die "active scopeのリポジトリが一致しない"
  [ "$(sed -n '2p' "$ACTIVE_SCOPE")" = "$FEATURE" ] || die "active scopeの機能名が一致しない"
  [ "$(sed -n '1p' "$ACTIVE_MODE")" = "subagent" ] || die "parent fallbackへhandoffできるのはsubagent modeだけ"
  TEMP_MODE="$ACTIVE_MODE.tmp.$$"
  printf 'parent-fallback\n' > "$TEMP_MODE" || die "parent fallback modeを書けない"
  mv "$TEMP_MODE" "$ACTIVE_MODE" || die "parent fallback modeを確定できない"
  implementation_scope_touch_lease || die "parent fallbackのleaseを更新できない"
  echo "handed-off: $FEATURE parent-fallback"
  exit 0
fi

if [ "${1:-}" = "recover-to-parent" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh recover-to-parent <機能名>"
  FEATURE=$2
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  [ -f "$ACTIVE_SCOPE" ] || die "activeな実装scopeが無い"
  [ -f "$ACTIVE_MODE" ] || die "activeな実装scopeのmodeが無い"
  [ -f "$ACTIVE_REQUEST" ] || die "activeなimplementation requestが無い"
  [ -f "$RECOVERY_OWNER_FILE" ] || die "hookが発行した復旧owner receiptが無い"
  [ "$(sed -n '1p' "$ACTIVE_SCOPE")" = "$REPOSITORY" ] || die "active scopeのリポジトリが一致しない"
  [ "$(sed -n '2p' "$ACTIVE_SCOPE")" = "$FEATURE" ] || die "active scopeの機能名が一致しない"
  MODE=$(sed -n '1p' "$ACTIVE_MODE")
  case "$MODE" in
    orphaned) ;;
    subagent|parent-fallback)
      implementation_scope_is_stale || die "active scopeのleaseは失効していない" ;;
    *) die "active scopeのmodeが不正" ;;
  esac
  RECOVERY_OWNER=$(sed -n '1p' "$RECOVERY_OWNER_FILE")
  [ -n "$RECOVERY_OWNER" ] || die "復旧owner receiptが空"
  collect_active_dirty_paths
  if [ "$DIRTY_PATHS" = '[]' ]; then
    RECOVERED_DIR="$RECEIPT_DIR/implementation.recovered.$$"
    mv "$ACTIVE_DIR" "$RECOVERED_DIR" || die "cleanな実装scopeを回収できない"
    rm -f "$RECOVERED_DIR/request.json" "$RECOVERED_DIR/lease"
    rm "$RECOVERED_DIR/mode" || die "回収済みscopeのmodeを解除できない"
    rm "$RECOVERED_DIR/scope" || die "回収済みscopeを解除できない"
    rmdir "$RECOVERED_DIR" || die "回収済みscope directoryを解除できない"
    rm -f "$OWNER_FILE" "$RECOVERY_OWNER_FILE"
    jq -n --arg feature "$FEATURE" '{outcome:"clean-deactivated",feature:$feature,next_action:"start-normal-flow"}'
    exit 0
  fi
  TEMP_MODE="$ACTIVE_MODE.tmp.$$"
  printf 'parent-fallback\n' > "$TEMP_MODE" || die "parent fallback modeを書けない"
  if ! mv "$RECOVERY_OWNER_FILE" "$OWNER_FILE"; then
    rm -f "$TEMP_MODE"
    die "復旧ownerを確定できない"
  fi
  mv "$TEMP_MODE" "$ACTIVE_MODE" || die "parent fallback modeを確定できない"
  implementation_scope_touch_lease || die "復旧後のleaseを更新できない"
  jq -n --arg feature "$FEATURE" --argjson dirty_paths "$DIRTY_PATHS" '{outcome:"parent-fallback",feature:$feature,next_action:"resume-active-request",dirty_paths:$dirty_paths}'
  exit 0
fi

if [ "${1:-}" = "deactivate" ]; then
  [ "$#" -eq 2 ] || die "usage: capture-scope.sh deactivate <機能名>"
  FEATURE=$2
  [[ "$FEATURE" =~ $FEATURE_RE ]] || die "invalid 機能名: $FEATURE (ASCII kebab-case only)"
  [ -f "$ACTIVE_SCOPE" ] || die "activeな実装subagent scopeが無い"
  [ -f "$ACTIVE_MODE" ] || die "activeな実装scopeのmodeが無い"
  [ "$(sed -n '1p' "$ACTIVE_SCOPE")" = "$REPOSITORY" ] || die "active scopeのリポジトリが一致しない"
  [ "$(sed -n '2p' "$ACTIVE_SCOPE")" = "$FEATURE" ] || die "active scopeの機能名が一致しない"
  case "$(sed -n '1p' "$ACTIVE_MODE")" in subagent|parent-fallback|orphaned) ;; *) die "active scopeのmodeが不正" ;; esac
  rm -f "$ACTIVE_REQUEST" "$ACTIVE_LEASE" "$RECOVERY_OWNER_FILE"
  rm "$ACTIVE_MODE" || die "active scopeのmodeを解除できない"
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
