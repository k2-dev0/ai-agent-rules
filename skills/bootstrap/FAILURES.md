# bootstrap 失敗時の確認

このファイルは `init-agent.sh` が失敗した場合だけ読む。

## 共通

- プロジェクトルートから、SKILL.md のコマンドを相対パスのまま単独実行する。
- `./`、絶対パス、`sh`、`cd ... &&`、pipe、separator、redirect を足さない。許可はコマンド文字列へ限定されている。
- placeholder 残存で終了した場合は、報告されたファイルを確認する。別の検索コマンドで終了条件を作り直さない。

## Claude Code

`Operation not permitted` なら、まずコマンド文字列を直す。正しい文字列でも失敗する場合だけ、古い配置で `settings.json` の `sandbox.excludedCommands` が欠けている可能性をユーザーへ報告し、sandbox 外の再実行と設定更新を依頼する。

## Codex

正しい文字列でも拒否された場合は、project trust と配布済み `.codex/rules/default.rules` を確認する。限定 allow を避ける別コマンドへ変更しない。
