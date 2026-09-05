#!/bin/bash
# PreToolUse(Write) hook: 既存ファイルの「全上書き」のうち、失われたら復元できない内容が
# ある場合だけ人間の確認に通す(ask)。git 管理下で clean なら棄権し、settings の allow に
# 委ねる(=自動書き込み)。可逆性で承認の密度を変えるための hook。
# 新規作成(存在しないパスへの Write)は素通り。既存ファイルの部分修正は Edit を使う前提。
# Why: ツール出力のノイズを「汚染された」と誤読したモデルが、記憶を頼りに既存ファイルを
#      全上書きして中身を消し飛ばす事故を、モデルの心境と無関係に harness 段階で止めるため。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
# hook_ask（deny ではない）を使う: 意図的な全面再生成なら人間が承認して通せる余地を残す
while IFS= read -r FILE; do
  [ -z "$FILE" ] && continue

  # 存在しないパス = 新規作成。素通りして settings の permission に委ねる
  [ -f "$FILE" ] || continue

  # git 管理下かつ未コミット差分なし = 上書きしても git で復元可能(可逆)。棄権して allow に委ねる
  DIR=$(dirname "$FILE")
  if git -C "$DIR" ls-files --error-unmatch -- ":(literal)$(basename "$FILE")" >/dev/null 2>&1; then
    [ -z "$(git -C "$DIR" status --porcelain -- ":(literal)$(basename "$FILE")")" ] && continue
    hook_ask "未コミット差分がある既存ファイルの全上書き(Write)です。承認すると未コミット分は復元できません。部分修正は Edit を使ってください。意図的な全面再生成であれば承認してください。"
  fi

  # git 管理外(untracked / repo 外) = 上書きで内容が完全消失(不可逆)。人間に諮る
  hook_ask "git 管理外ファイルの全上書き(Write)です。承認すると元の内容は復元できません。部分修正は Edit を使ってください。意図的な全面再生成であれば承認してください。"
done < <(hook_file_paths)
exit 0
