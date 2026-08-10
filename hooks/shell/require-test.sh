#!/bin/bash
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
TOOL=$(hook_tool_name)

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

    # テストファイル自体は TDD の Red フェーズ。deny 対象外(棄権して settings に委ねる)
    echo "$FILE" | grep -q '\.test\.' && continue

    # Prisma schemaは対応テストではなく format / validate / generate で検証する。
    # 拡張子判定の偶然に依存せず、TDD契約上の明示的な除外として固定する。
    case "$FILE" in
      schema.prisma|*/schema.prisma) continue ;;
    esac

    # JSX/TSX componentとReact hookには隣接unit testを強制しない。
    # hookは慣例的なdirectory・basenameだけを対象にし、一般のuse語を誤除外しない。
    case "$FILE" in
      */hooks/*|*/use[A-Z]*.ts|*/use[A-Z]*.js|*/use-*.ts|*/use-*.js|*.hook.ts|*.hook.js) continue ;;
    esac

    DIR=$(dirname "$FILE")
    BASE=$(basename "$FILE" | sed 's/\.[^.]*$//')
    EXT=$(basename "$FILE" | sed 's/^.*\.//')

    # ロジックファイル(ts/js)のみ対象。tsx/jsx は意図的な除外 — コンポーネントのテストは
    # モックや {} での辻褄合わせに堕ちやすく強制する価値が薄いため、テストを門前払いの
    # 条件にしない(書きたければ tdd に任意で乗せられる)。.md .json .sh 等も対象外
    case "$EXT" in
      ts|js) ;;
      *) continue ;;
    esac

    TEST_FILE="$DIR/$BASE.test.$EXT"
    [ -f "$TEST_FILE" ] || \
      hook_deny "テストファイル($TEST_FILE)が無い状態でのコード実装は禁止です。起動中のtddまたはerrandの共通フロー（シナリオ → Red → Green）に乗せてください。"
  done < <(hook_file_paths)

  # 対応テストがあるコード本体 = 棄権して settings の permission 層に委ねる。
  # 自動化(allow Edit(**)/Write(**))も停止(ask: auth/migrations 等)も settings が決める
  exit 0
fi

exit 0
