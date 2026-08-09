#!/bin/bash
# apply-prompt: draft-prompt/ のドラフト一式を .[agent_name]/prompt/ へ移して draft-prompt/ を畳む。
# .[agent_name]/ は sandbox の denyWrite で保護されており、エージェントは直接書き込めない。
# 移動元・宛先・受け入れるファイル名をすべて本スクリプト内に固定することで、
# サンドボックス外実行の事前 allow を「draft-prompt/ から .[agent_name]/prompt/ への移動」に限定する。
# 使い方: bash apply-prompt.sh   ← 引数は取らない
#   draft-prompt/ の中身は .prompt.md（実装順の index）と
#   branch-<機能名>-prompt.md（機能ごとの設計書）だけ。他のファイルが 1 つでもあれば失敗する。
# 削除について: 反映後に draft-prompt/ を畳むが、消せるのは「固定パスのディレクトリと、
#   そこにある検証済みの index / 設計書」だけ。引数が存在しないため削除先を外から動かせず、
#   rm の ask ゲートを迂回する任意ファイル削除の抜け道にはならない。rm -rf は使わない。
# 失敗の扱い: 検証エラー・cp 失敗はすべて exit 1（握りつぶし禁止）。宛先には一切触れない。
set -u

SRC_DIR="draft-prompt"
DEST_DIR=".[agent_name]/prompt"
INDEX_NAME=".prompt.md"
# 機能名は ASCII の kebab-case に限定する。branch- 接頭辞のとおり git のブランチ名として
# そのまま使える文字集合に揃え、あわせて glob と検証を単純に保つため。
FEATURE_RE='^branch-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?-prompt\.md$'

die(){ echo "ERROR: $1" >&2; exit 1; }

[ -L "$SRC_DIR" ] && die "draft dir is a symlink: $SRC_DIR"
[ -d "$SRC_DIR" ] || die "draft dir not found: $SRC_DIR (cowlick で先にドラフトを作ること)"
[ -f "$SRC_DIR/$INDEX_NAME" ] || die "index not found: $SRC_DIR/$INDEX_NAME"

# ドラフトディレクトリの中身を検査する。index と設計書以外が 1 つでもあれば止める。
# 「中身を絞る」ことが「固定宛先へ書き込めるファイルを絞る」ことと同義になる。
FILES=""
for path in "$SRC_DIR"/* "$SRC_DIR"/.[!.]*; do
  [ -e "$path" ] || continue
  name="${path##*/}"
  [ -L "$path" ] && die "draft entry is a symlink: $name"
  [ -f "$path" ] || die "draft entry is not a regular file: $name"
  [ "$name" = "$INDEX_NAME" ] && continue
  [[ "$name" =~ $FEATURE_RE ]] || die "unexpected draft file: $name (expected $INDEX_NAME or branch-<機能名>-prompt.md)"
  FILES="$FILES$name
"
done
[ -n "$FILES" ] || die "no design doc in $SRC_DIR (branch-<機能名>-prompt.md required)"

# index の実装順リストが壊れた行を含んでいないか検査する。
BAD=$(grep -nE '^[[:space:]]*-[[:space:]]*\[[ xX]\]' "$SRC_DIR/$INDEX_NAME" \
  | grep -vE '^[0-9]+:[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]+branch-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?-prompt\.md[[:space:]]*$')
[ -n "$BAD" ] && die "malformed index entry:
$BAD"

# index が並べた設計書と、実体として存在する設計書が 1:1 で対応することを検査する。
# 食い違ったまま反映すると tdd from-prompt が存在しないファイルを掴む／実装されない設計書が残る。
REFS=$(grep -oE 'branch-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?-prompt\.md' "$SRC_DIR/$INDEX_NAME" | sort -u)
HAVE=$(printf '%s' "$FILES" | sort -u)
[ "$REFS" = "$HAVE" ] || die "index と設計書が一致しない
  index が並べた設計書:
$REFS
  実体のある設計書:
$HAVE"

[ -L "$DEST_DIR" ] && die "dest dir is a symlink: $DEST_DIR"
mkdir -p "$DEST_DIR" || die "cannot create dir: $DEST_DIR"
# 宛先側が symlink だと cp がリンク先を上書きし「宛先固定」の前提が崩れるため拒否する。
[ -L "$DEST_DIR/$INDEX_NAME" ] && die "dest is a symlink: $DEST_DIR/$INDEX_NAME"
for path in "$DEST_DIR"/branch-*-prompt.md; do
  [ -L "$path" ] && die "dest entry is a symlink: $path"
done

# 前タスクの設計書が残ると index と実体が食い違うため、今回の一式に無いものだけを削除する。
for path in "$DEST_DIR"/branch-*-prompt.md; do
  [ -e "$path" ] || continue
  name="${path##*/}"
  printf '%s\n' "$HAVE" | grep -qFx "$name" && continue
  rm -f -- "$path" || die "cannot remove stale design doc: $path"
  echo "removed: $path"
done

cp -- "$SRC_DIR/$INDEX_NAME" "$DEST_DIR/$INDEX_NAME" || die "copy failed: $INDEX_NAME"
echo "applied: $DEST_DIR/$INDEX_NAME"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  cp -- "$SRC_DIR/$name" "$DEST_DIR/$name" || die "copy failed: $name"
  echo "applied: $DEST_DIR/$name"
done <<EOF
$HAVE
EOF

# 反映が全件成功してから draft-prompt/ を畳む。検証済みのファイルを 1 つずつ消して rmdir する。
# rmdir なので、想定外のものが残っていれば畳めずに残る（再帰削除で巻き込むことはない）。
rm -f -- "$SRC_DIR/$INDEX_NAME" || die "cannot remove draft: $SRC_DIR/$INDEX_NAME"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  rm -f -- "$SRC_DIR/$name" || die "cannot remove draft: $SRC_DIR/$name"
done <<EOF
$HAVE
EOF
if rmdir "$SRC_DIR" 2>/dev/null; then
  echo "cleaned: $SRC_DIR"
else
  echo "WARN: $SRC_DIR に想定外のファイルが残っているため畳めなかった。中身を確認して手で消すこと" >&2
fi
