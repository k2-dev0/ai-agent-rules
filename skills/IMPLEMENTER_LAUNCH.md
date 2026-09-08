# implementerの起動

[子・待機の規則](SUBAGENT_RULES.md)を満たす独立した並列実装に限り、[実装契約](IMPLEMENTER_CONTRACT.md)に従う専用agentを新規起動する。

briefには担当する全要件、確認済み事実と`path:line`、不変条件、担当path・変更禁止範囲、適用規約・既存例、選択済みシナリオ、確認済みtest commandとRed結果、完了条件だけを渡す。

| 環境 | 指定 |
|---|---|
| Codex native API | `agent_type: "implementer"`と、対応する`fork_context: false`または`fork_turns: "none"` |
| Claude Agent | `subagent_type: "implementer"` |

model・effortは省略し、専用定義の設定・権限を使う。resume・backgroundは指定しない。role選択欄がなければ対応するnative toolを探し、利用不能ならメインで続行する。

起動hookの拒否理由に従って入力・配置を確認する。親がplan/read-onlyなら必要な権限を親側で確認する。代替role、指示本文のコピー、global設定変更、sandbox無効化で回避しない。手動preflightは不要。

## 待機・識別

返却されたchild IDまたは待機可能なtask pathでサブエージェントの完了を確認する。待機先なしは起動失敗。実行中の子がないことを確認してからメインへ戻す。

`agent_role`で識別し、戻り値にない場合はmetadata・実行記録を確認する。`agent_nickname`からroleを推測しない。報告はroleを先に示し、要求と異なるrole・実効設定なら続行しない。
