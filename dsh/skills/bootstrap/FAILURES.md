# bootstrap失敗時

`bootstrap.sh`が失敗した場合だけ読む。

| 結果 | 対応 |
|---|---|
| コマンド形式が違う | プロジェクトルートからSKILL.mdの相対pathを単独実行。`./`・絶対path・sh・cd・pipe・separator・redirectを足さない |
| placeholder残存 | 報告されたfileを確認。終了条件を別の検索で作り直さない |
| `bootstrap cannot run in the source repository` | 配置先で実行 |
| `cannot inspect ...` | 配置先の読み取り権限を修正 |
| `cannot remove bootstrap skill from discovery` | bootstrapの残存と親directoryの権限を確認・修正 |
| Claudeで正しいcommandも`Operation not permitted` | `sandbox.excludedCommands`を確認し、設定更新とsandbox外実行を依頼 |
| Codexで正しいcommandも拒否 | project trustと`.codex/rules/default.rules`を確認 |

固定入口を別コマンドで代用しない。配置・権限・script自体の修復が必要なら配布元の修正またはユーザーの対応を求め、エージェント自身の保護設定を変更して続行しない。
