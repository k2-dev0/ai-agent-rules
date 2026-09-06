# implementerの呼び出し方

初回実装・再実装を専用implementerへ渡す親向けの操作資料。工程とbriefは呼び出し元のフロー、実装役の担当範囲は[実装契約](IMPLEMENTER_CONTRACT.md)で定める。

## 起動

- Codexは専用定義を選べるnative APIで`agent_type: "implementer"`を指定し、そのAPIにある`fork_context: false`または`fork_turns: "none"`を使う。
- Claude CodeはAgentの`subagent_type: "implementer"`を指定する。
- modelとeffortの引数は省略する。モデル・effort・権限は配布済みagent定義を使い、起動時に`require-implementer.sh`が引数・専用設定・共通契約を検査する。手動preflightは不要。
- 一体だけを新規に起動する。resumeとbackground指定は使わない。現在のAPIに専用roleの選択欄が無ければ対応するnative toolを探し、利用できなければ委任を停止する。

hookの拒否理由に従って入力や配置を確認する。親がplan / read-onlyの場合は、必要な権限を親側で一度確認する。代替roleの起動、指示本文のコピー、global設定の変更、sandbox無効化で拒否を回避しない。

## 待機と識別

APIが返したchild agent ID、または待機先として扱えるtask pathを使い、完了まで待つ。wait先が空なら起動成功に数えない。短周期poll、固定時間での打ち切り、別implementerの並列起動は行わない。

実行記録では`agent_role`で識別する。戻り値にroleがなければ子のmetadataまたは保存された実行記録を確認し、表示名から推測しない。Huygens等の`agent_nickname`は表示名であり、報告は「implementer（表示名: Huygens）」のようにroleを先に示す。要求と異なるrole・実効設定が判明したら続行しない。
