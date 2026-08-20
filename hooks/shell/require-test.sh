#!/bin/bash
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
TOOL=$(hook_tool_name)
REPOSITORY=$(git -C "$(hook_cwd)" rev-parse --show-toplevel 2>/dev/null) || exit 0
REPOSITORY_PHYSICAL=$(cd "$REPOSITORY" 2>/dev/null && pwd -P) || exit 0
REPOSITORY_KEY=$(printf '%s' "$REPOSITORY" | cksum | awk '{ print $1 }')
ACTIVE_REQUEST="${TMPDIR:-/tmp}/polish-quality-gate/$REPOSITORY_KEY/implementation.active/request.json"

request_allows_test_mapping() {
  local file=$1 test_path
  [ -f "$ACTIVE_REQUEST" ] || return 1
  jq -e --arg file "$file" '(.allowed_paths | index($file)) != null' "$ACTIVE_REQUEST" >/dev/null 2>&1 || return 1
  jq -e '.test_exemption != null' "$ACTIVE_REQUEST" >/dev/null 2>&1 && return 0
  while IFS= read -r test_path; do
    [ -f "$REPOSITORY/$test_path" ] || return 1
    if ! git -C "$REPOSITORY" ls-files --error-unmatch -- ":(literal)$test_path" >/dev/null 2>&1; then
      git -C "$REPOSITORY" check-ignore -q -- "$test_path" || return 1
    fi
  done < <(jq -r '.test_paths[]' "$ACTIVE_REQUEST")
  [ "$(jq '.test_paths | length' "$ACTIVE_REQUEST")" -gt 0 ]
}

tracked_test_with_same_basename_exists() {
  local base=$1 ext=$2 tracked
  while IFS= read -r tracked; do
    case "$(basename "$tracked")" in
      "$base.test.$ext"|"$base.spec.$ext") [ -f "$REPOSITORY/$tracked" ] && return 0 ;;
    esac
  done < <(git -C "$REPOSITORY" ls-files)
  return 1
}

# codex では session marker（$tdd / $errand 起動時に session.sh が記録）が
# 現セッションを指す時だけ執行する。claude は各skillのfrontmatter hooksが起動を絞る。
if [ "$HOOK_AGENT" = "codex" ] && ! { hook_skill_session_active "tdd" || hook_skill_session_active "errand"; }; then
  exit 0
fi

# 本 hook は deny(執行)専任。allow は返さない — ask/deny ルールは hook の allow より
# 常に優先される(公式仕様)ので素通りの危険は無いが、自動化は settings.local.json の
# allow(Edit(**)/Write(**)) が既に担っており、hook 側の allow は密度の定義を二重化する
# だけの死荷重になるため。

# [NOTE]: bootstrap 対象
# claude code: if [ "$TOOL" = "Edit" ] || [ "$TOOL" = "Write" ]; then
# codex: if [ "$TOOL" = "apply_patch" ]; then
if 
  # 複数ファイル入力(codex の apply_patch)に備え、1 件でも違反があれば deny する
  while IFS= read -r FILE; do
    [ -z "$FILE" ] && continue

    case "$FILE" in
      "$REPOSITORY"/*) RELATIVE_FILE=${FILE#"$REPOSITORY/"} ;;
      "$PWD"/*)
        PWD_REPOSITORY=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)
        PWD_REPOSITORY_PHYSICAL=$(cd "$PWD_REPOSITORY" 2>/dev/null && pwd -P || true)
        if [ "$PWD_REPOSITORY_PHYSICAL" = "$REPOSITORY_PHYSICAL" ]; then
          RELATIVE_FILE=${FILE#"$PWD/"}
        else
          RELATIVE_FILE=$FILE
        fi
        ;;
      /*)
        FILE_PARENT=$(dirname "$FILE")
        [ -d "$FILE_PARENT" ] || hook_deny "編集pathの親directoryが存在しません: $FILE"
        CANONICAL_FILE="$(cd "$FILE_PARENT" 2>/dev/null && pwd -P)/$(basename "$FILE")"
        case "$CANONICAL_FILE" in
          "$REPOSITORY_PHYSICAL"/*) RELATIVE_FILE=${CANONICAL_FILE#"$REPOSITORY_PHYSICAL/"} ;;
          *) RELATIVE_FILE=$FILE ;;
        esac
        ;;
      *) RELATIVE_FILE=$FILE ;;
    esac

    # テストファイル自体は TDD の Red フェーズ。deny 対象外(棄権して settings に委ねる)
    echo "$RELATIVE_FILE" | grep -Eq '\.(test|spec)\.' && continue

    # Prisma schemaと定数定義は対応テストを要求しない。
    # 拡張子判定の偶然に依存せず、TDD契約上の明示的な除外として固定する。
    case "$RELATIVE_FILE" in
      schema.prisma|*/schema.prisma|constants.ts|*/constants.ts|constants.js|*/constants.js|constants/*|*/constants/*) continue ;;
    esac

    # JSX/TSX componentとReact hookには隣接unit testを強制しない。
    # hookは慣例的なdirectory・basenameだけを対象にし、一般のuse語を誤除外しない。
    case "$RELATIVE_FILE" in
      */hooks/*|*/use[A-Z]*.ts|*/use[A-Z]*.js|*/use-*.ts|*/use-*.js|*.hook.ts|*.hook.js) continue ;;
    esac

    BASE=$(basename "$RELATIVE_FILE" | sed 's/\.[^.]*$//')
    EXT=$(basename "$RELATIVE_FILE" | sed 's/^.*\.//')

    # ロジックファイル(ts/js)のみ対象。tsx/jsx は意図的な除外 — コンポーネントのテストは
    # モックや {} での辻褄合わせに堕ちやすく強制する価値が薄いため、テストを門前払いの
    # 条件にしない(書きたければ tdd に任意で乗せられる)。.md .json .sh 等も対象外
    case "$EXT" in
      ts|js) ;;
      *) continue ;;
    esac

    request_allows_test_mapping "$RELATIVE_FILE" && continue
    tracked_test_with_same_basename_exists "$BASE" "$EXT" && continue
    hook_deny "承認済みimplementation requestのtest_paths、または同じbasenameの追跡済みtest/specが無い状態でのコード実装は禁止です。隣接配置は必須ではありません。ignore規則に一致するローカルtestはtest_pathsで明示すれば使用できます。"
  done < <(hook_file_paths)

  # 対応テストがあるコード本体 = 棄権して settings の permission 層に委ねる。
  # 自動化(allow Edit(**)/Write(**))も停止(ask: auth/migrations 等)も settings が決める
  exit 0
fi

exit 0
