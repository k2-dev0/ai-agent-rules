#!/bin/bash
# bootstrap: 配置済みエージェント設定ツリーの placeholder を確定させる決定的スクリプト。
# [agent_name] / [skills_root] の置換と [NOTE]: bootstrap 対象 ブロックの解決を、
# レビュー済みの単一成果物として実行する（その都度インタプリタで書き捨てコードを生成しないため）。
# 使い方: bash init-agent.sh <claude|codex>
# 失敗の扱い: 置換失敗・[NOTE] 未解決（tmp 書き込み不能 / bare if 不在）が 1 件でも
# あれば exit 1。成功ログは実際に書き換えできた時だけ出す（失敗の握りつぶし禁止）。
set -u

AGENT="${1:?usage: init-agent.sh <claude|codex>}"

# 配布元には削除対象の原本がある。配置先だけで実行する契約を機械的に守る。
[ ! -e SOURCE_REPOSITORY.md ] || {
  echo "ERROR: bootstrap cannot run in the source repository" >&2
  exit 1
}

# 種別ごとに: 設定ディレクトリ / 置換値 / skills 配置先 / [NOTE] 確定条件 を決める。
# codex の skills 配置先が .agents/skills なのは codex 側の探索仕様
# （リポジトリ内は .agents/skills しか読まない）による
case "$AGENT" in
  claude) DIR=".claude"; NAME="claude"; SKILLS_ROOT=".claude/skills"
    COND='if [ "$TOOL" = "Edit" ] || [ "$TOOL" = "Write" ] || [ "$TOOL" = "MultiEdit" ]; then' ;;
  codex)  DIR=".codex";  NAME="codex"; SKILLS_ROOT=".agents/skills"
    COND='if [ "$TOOL" = "apply_patch" ]; then' ;;
  *) echo "unknown agent: $AGENT (claude|codex)" >&2; exit 1 ;;
esac
[ -d "$DIR" ] || { echo "config dir not found: $DIR" >&2; exit 1; }

# 置換対象: 設定ツリー + AGENTS.md（コミット契約タグ等の placeholder を含む）+
# 設定ディレクトリの外に置かれる skills ツリー（codex の .agents）
TARGETS="$DIR"
[ -f AGENTS.md ] && TARGETS="$TARGETS AGENTS.md"
case "$SKILLS_ROOT" in
  "$DIR"/*) ;;
  *) [ -d "${SKILLS_ROOT%/*}" ] && TARGETS="$TARGETS ${SKILLS_ROOT%/*}" ;;
esac

# grep | while はサブシェル化して失敗フラグが親に届かないため、プロセス置換で読む。
# set -e はパイプライン内 while で期待どおり働かないので使わず、明示的に成否判定する
FAILED=0

# 1) placeholder 置換: bootstrap スキル自身（placeholder の説明文と処理本体）は除外する
PLACEHOLDER_FILES=$(grep -rlE '\[agent_name\]|\[skills_root\]' $TARGETS)
SEARCH_STATUS=$?
if [ "$SEARCH_STATUS" -gt 1 ]; then
  echo "ERROR: cannot inspect placeholders" >&2
  exit 1
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */bootstrap/*) continue ;; esac
  if sed -i.bak "s|\[skills_root\]|$SKILLS_ROOT|g; s/\[agent_name\]/$NAME/g" "$f"; then
    rm -f "$f.bak"
    echo "replaced placeholders -> $NAME : $f"
  else
    rm -f "$f.bak"
    echo "ERROR: replace failed (sed): $f" >&2
    FAILED=1
  fi
done <<< "$PLACEHOLDER_FILES"

# 2) [NOTE] 解決: [NOTE] 行から直後の bare if 行までを確定条件へ畳む（bootstrap 自身は除外）
NOTE_FILES=$(grep -rl '\[NOTE\]: bootstrap' $TARGETS)
SEARCH_STATUS=$?
if [ "$SEARCH_STATUS" -gt 1 ]; then
  echo "ERROR: cannot inspect bootstrap notes" >&2
  exit 1
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */bootstrap/*) continue ;; esac
  WAS_EXECUTABLE=false
  [ -x "$f" ] && WAS_EXECUTABLE=true
  if ! awk -v cond="$COND" '
    /\[NOTE\]: bootstrap/ { skip=1; next }
    skip && /^[[:space:]]*if[[:space:]]*$/ { print cond; skip=0; next }
    skip { next }
    { print }
  ' "$f" > "$f.tmp"; then
    rm -f "$f.tmp"
    echo "ERROR: cannot write tmp for [NOTE] resolve: $f.tmp" >&2
    FAILED=1
    continue
  fi
  if ! grep -qF "$COND" "$f.tmp"; then
    # マーカーがあるのに bare if が無い = 配置ツリーが壊れている。黙って続行すると
    # マーカーが残ったまま成功に見えるため、失敗として報告する
    rm -f "$f.tmp"
    echo "ERROR: bare if not found, cannot resolve [NOTE]: $f" >&2
    FAILED=1
    continue
  fi
  if [ "$WAS_EXECUTABLE" = true ] && ! chmod +x "$f.tmp"; then
    rm -f "$f.tmp"
    echo "ERROR: cannot preserve executable bit: $f" >&2
    FAILED=1
    continue
  fi
  if mv "$f.tmp" "$f"; then
    echo "resolved [NOTE] : $f"
  else
    rm -f "$f.tmp"
    echo "ERROR: cannot overwrite (mv failed): $f" >&2
    FAILED=1
  fi
done <<< "$NOTE_FILES"

# 3) 置換後検証: 承認済みの固定スクリプト内で完結させ、別の shell 承認を発生させない
UNRESOLVED_FILES=$(grep -rlE '\[agent_name\]|\[skills_root\]' $TARGETS)
SEARCH_STATUS=$?
if [ "$SEARCH_STATUS" -gt 1 ]; then
  echo "ERROR: cannot verify placeholders" >&2
  FAILED=1
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */bootstrap/*) continue ;; esac
  echo "ERROR: unresolved placeholder: $f" >&2
  FAILED=1
done <<< "$UNRESOLVED_FILES"

[ "$FAILED" -eq 0 ] || exit "$FAILED"

# 成功後は次回セッションで不要なskillを探索させない。削除先はagent種別から決まる
# 2パスだけに限定し、配置異常時は削除せず失敗する。
BOOTSTRAP_DIR="$SKILLS_ROOT/bootstrap"
case "$BOOTSTRAP_DIR" in
  .claude/skills/bootstrap) BOOTSTRAP_TRASH=".claude/.bootstrap-removing.$$" ;;
  .agents/skills/bootstrap) BOOTSTRAP_TRASH=".agents/.bootstrap-removing.$$" ;;
  *) echo "ERROR: unsafe bootstrap directory: $BOOTSTRAP_DIR" >&2; exit 1 ;;
esac
[ -d "$BOOTSTRAP_DIR" ] || {
  echo "ERROR: bootstrap directory not found: $BOOTSTRAP_DIR" >&2
  exit 1
}
[ ! -e "$BOOTSTRAP_TRASH" ] || {
  echo "ERROR: bootstrap quarantine already exists: $BOOTSTRAP_TRASH" >&2
  exit 1
}
if ! mv "$BOOTSTRAP_DIR" "$BOOTSTRAP_TRASH"; then
  echo "ERROR: cannot remove bootstrap skill from discovery: $BOOTSTRAP_DIR" >&2
  exit 1
fi
[ ! -e "$BOOTSTRAP_DIR" ] || {
  echo "ERROR: bootstrap skill remains: $BOOTSTRAP_DIR" >&2
  exit 1
}
if ! rm -rf -- "$BOOTSTRAP_TRASH"; then
  echo "WARNING: bootstrap quarantine could not be cleaned: $BOOTSTRAP_TRASH" >&2
fi
echo "removed bootstrap skill: $BOOTSTRAP_DIR"
