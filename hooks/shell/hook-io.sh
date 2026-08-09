#!/bin/bash
# hook-io: PreToolUse hook の入出力スキーマ差分をエージェント種別ごとに吸収するアダプタ。
# 各 hook は stdin の JSON や決定 JSON の形式に直接触れず、本ファイルの関数だけを使う。
# Why: [NOTE] 機構が吸収するのはツール名の差分だけで、入力(.tool_name / .tool_input)と
#      出力(hookSpecificOutput)のスキーマは Claude Code 固有のまま各 hook に散っていた。
#      スキーマの読み書きを本ファイルへ集約し、エージェント追加時はここへの分岐追加だけで
#      済ませる。
# 使い方: hook 冒頭で `. "$(dirname "$0")/hook-io.sh"` と source する。
#         source 時点で stdin を読み切り HOOK_INPUT へ保持する。
# 決定 hook の共通契約: stdout には決定 JSON 以外を出さない。stderr は各 hook が冒頭の
#         exec 2>/dev/null で捨てる（jq 等サブプロセスのエラー文字混入を断つ）。
# エージェント名 placeholder は配置後に bootstrap が確定させる。

HOOK_AGENT="[agent_name]"

# 入力は種別 / jq の判定より前に読み切る。下の hook_io_fatal がイベント種別を見るため。
HOOK_INPUT=$(cat)

# 設定不備で hook が機能しないときの終了口。
# exit 1 は PreToolUse では "non-blocking error" 扱いとなりツールはそのまま実行される。
# つまり「安全側に倒したつもりの非ゼロ終了」が実際には全ガードの fail-open になる。
# よって PreToolUse では deny 決定 JSON を直接書き出して確実に止める。
# jq 不在時も出せるよう printf で組む（理由文は自前のリテラルのみでエスケープ不要）。
# 各 hook は冒頭で stderr を捨てるため、原因はこの理由文でしかエージェントに届かない。
# PreToolUse 以外（session.sh の UserPromptSubmit / SessionEnd）で同じ JSON を
# 出すと、exit 0 の stdout がプロンプトへの追加コンテキストとして注入されるので棄権する。
# 棄権しても、marker 生成の失敗で緩む require-test.sh 自身が PreToolUse 側で deny
# されるため fail-open にはならない。
hook_io_fatal() {
  case "$HOOK_INPUT" in
    *'"hook_event_name"'*'"PreToolUse"'*)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
      ;;
  esac
  exit 0
}

# 未実装エージェントの即死: スキーマ不明のまま進むと jq が空を返し「全ファイル素通し」
# という最悪の静かな故障になるため、判定せず deny に倒す。
# codex: main ソース + 実機 probe（v0.145.0、2026-07-27）で入出力とも Claude 互換を
#   確定済み。Bash 系は {"command": <文字列>}、apply_patch は {"command": <パッチ全文>}
#   で file_path 無し → hook_file_paths がパッチを解析する
case "$HOOK_AGENT" in
  claude|codex) ;;
  *)
    # placeholder 未解決 = 未初期化。ここで一律 deny すると placeholder を解決する
    # bootstrap 自身の起動まで止まって詰むため、その 1 コマンドだけ通す
    case "$HOOK_INPUT" in
      *bootstrap/init-agent.sh*) exit 0 ;;
    esac
    hook_io_fatal "エージェント種別が未確定です（hook-io.sh の HOOK_AGENT が placeholder のまま）。bootstrap スキルを実行して配置を初期化してください。"
    ;;
esac

# jq 不在は全 hook の静かな無効化（空抽出 → 全件素通し）になるため、判定せず deny に倒す。
# 「jq が無い」の報告自体に jq を使えないので hook_io_fatal（printf 実装）を使う
command -v jq >/dev/null 2>&1 || \
  hook_io_fatal "jq が見つからないため hook が機能しません。全ガードが無効な状態での実行は許可できません。ユーザー自身のシェルで jq を導入してください（macOS: brew install jq）。"

# 呼び出し元ツールの名前を返す関数
hook_tool_name() { echo "$HOOK_INPUT" | jq -r '.tool_name'; }

# 編集対象のファイルパスを改行区切りで列挙する関数（0 件なら何も出さない）。
# claude: file_path / notebook_path の単一パス。
# codex: apply_patch の tool_input に file_path は無く {"command": "<パッチ全文>"} のみ
#        （main ソース確定 2026-07）のため、パッチの対象ファイル行から抽出する
hook_file_paths() {
  case "$HOOK_AGENT" in
    codex)
      if [ "$(hook_tool_name)" = "apply_patch" ]; then
        echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty' | \
          sed -nE -e 's/^\*\*\* (Add|Update|Delete) File: //p' -e 's/^\*\*\* Move to: //p'
      else
        echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty'
      fi ;;
    *)
      echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' ;;
  esac
}

# 実行されようとしているシェルコマンド文字列を返す関数（取れなければ空）
hook_command() { echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty'; }

# セッション ID を返す関数（取れなければ空）
hook_session_id() { echo "$HOOK_INPUT" | jq -r '.session_id // empty'; }

# 作業ディレクトリを返す関数（取れなければ空）
hook_cwd() { echo "$HOOK_INPUT" | jq -r '.cwd // empty'; }

# UserPromptSubmit のプロンプト文字列を返す関数（取れなければ空）
hook_prompt() { echo "$HOOK_INPUT" | jq -r '.prompt // empty'; }

# hook イベント名（PreToolUse / UserPromptSubmit / SessionEnd 等）を返す関数
hook_event_name() { echo "$HOOK_INPUT" | jq -r '.hook_event_name // empty'; }

# session marker のパスを返す関数（codex の skill スコープ再現に使う）。
# セッション別のファイル名にして、並行セッション同士の上書き競合を構造的に無くす。
# 残留 marker は別 session_id のファイルなので無害（SessionEnd の掃除でも消える）
hook_skill_session_file() { echo "$(hook_cwd)/.codex/tmp/session.$1.$(hook_session_id)"; }

# 指定スキルの marker が現在のセッションに存在するか判定する関数
hook_skill_session_active() { [ -f "$(hook_skill_session_file "$1")" ]; }

# 決定 JSON(deny)を組み立てる。出力前にreceipt等を確定するhookからも再利用する。
hook_deny_json() {
  jq -n --arg r "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
}

# 決定 JSON(deny)を stdout へ出し、理由をエージェントに伝えて hook を終える関数
hook_deny() {
  hook_deny_json "$1"
  exit 0
}

# Bash コマンドを副作用のない等価表現へ正規化して実行を続ける関数。
# updatedInput は allow 決定と同時に返す必要があるため、呼び出し側で JSON を組ませない。
hook_rewrite_command() {
  jq -n --arg c "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":$c}}}'
  exit 0
}

# 人間の確認を要求する関数。Claude は ask 決定を返せるが、Codex の PreToolUse は
# permissionDecision=ask を未サポートで、hook failure としてツール実行を継続してしまう。
# Codex の確認操作は .codex/rules へ定義し、誤配線時は deny に倒して fail-open を防ぐ。
hook_ask() {
  case "$HOOK_AGENT" in
    claude)
      jq -n --arg r "$1" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
      exit 0
      ;;
    codex)
      hook_deny "Codex の PreToolUse hook は ask をサポートしません。default.rules に承認ルールを定義してください。元の理由: $1"
      ;;
  esac
}
