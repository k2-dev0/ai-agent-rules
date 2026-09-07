# implementerの起動

[実装契約](IMPLEMENTER_CONTRACT.md)と[子・待機の規則](SUBAGENT_RULES.md)に従う専用agentを一体だけ新規起動する。briefは呼び出し元のフローに従う。

| 環境 | 指定 |
|---|---|
| Codex native API | `agent_type: "implementer"`と、対応する`fork_context: false`または`fork_turns: "none"` |
| Claude Agent | `subagent_type: "implementer"` |

model・effortは省略し、専用定義の設定・権限を使う。resume・backgroundは指定しない。role選択欄がなければ対応するnative toolを探し、利用不能なら停止する。

起動hookの拒否理由に従って入力・配置を確認する。親がplan/read-onlyなら必要な権限を親側で確認する。代替role、指示本文のコピー、global設定変更、sandbox無効化で回避しない。手動preflightは不要。

## 待機・識別

返却されたchild IDまたは待機可能なtask pathで完了まで待つ。待機先なしは起動失敗。短周期poll・固定時間の打ち切り・別implementerの並列起動は禁止。

`agent_role`で識別し、戻り値にない場合はmetadata・実行記録を確認する。`agent_nickname`からroleを推測しない。報告はroleを先に示し、要求と異なるrole・実効設定なら続行しない。
