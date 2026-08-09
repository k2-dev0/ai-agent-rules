# DeepSeek委任の共通契約

DeepSeekを呼ぶスキルは、この文書を全文読んでから実行する。個別スキルと矛盾する場合は、対象範囲などmode固有の制約を個別スキルから、この文書のCLI・時間・失敗処理を共通契約として適用する。

各workflow入口はsessionで最初の委任前に`bash [skills_root]/deepseek/delegate.sh prepare`を実行する。初回はhookがこの契約全文をcontextへ注入して操作を止めるため、内容を反映して`prepare`を再実行してから対象modeへ進む。同じworkflow配下のskillはこの準備を共有する。同一session・同一契約内容のreceiptはtask-idやmodeに依存せず、後続の`prepare`と委任で全文を再注入しない。

## 責務

| 工程 | 担当 |
|---|---|
| 設計に必要な探索・根拠収集、ネストなどの機械的検出 | DeepSeek |
| 設計・要件・候補の採否、実装を修正する／しないの判断 | 上位モデル |
| 承認済み範囲の初回実装 | DeepSeek |
| 候補返却後のレビュー・修正・テスト・Git | 上位モデル。レビューや修正をDeepSeekへ戻さない |

固定実行器より先、または実行中に、同じ仕事をAgent / subagentへ並行委任しない。

## CLIと時間選択

`survey`、`research`、`implement`、`errand`、`nesting`は次の順で時間方針と理由を必須指定する。

```bash
bash [skills_root]/deepseek/delegate.sh <mode> \
  --hard-timeout-minutes <2..60> \
  --idle-timeout-seconds <30..900> \
  --poll-seconds <2..60> \
  --timeout-reason "scope=<対象範囲>,difficulty=<low|medium|high>,basis=<選択根拠>" \
  <mode固有の引数>
```

上位モデルは実行前に対象ファイル数、探索境界、実装量、外部境界、難易度を評価して値と理由をユーザーへ明示する。実行器は次も強制する。

- idle timeoutにpollが3回以上入る
- hard timeoutにidle timeoutが2区間以上入る
- reasonは24文字以上で、`scope=`、`difficulty=`、`basis=`を含む

固定値を惰性で再利用しない。再試行では新しいtask-idを使い、reasonへ`previous=<失敗種別>; adjustment=<変更理由>`を加え、値を維持または変更する根拠を明示する。理由へ機密情報を含めない。選択値とreasonはtask stateと`result.json`へ保存される。

`smoke`は固定疎通確認なので時間引数を取らない。従量課金のため、ユーザーが明示的に許可した場合だけ実行する。完了済み結果の再表示は`bash [skills_root]/deepseek/delegate.sh show <task-id>`を使う。同期実行中に`show`や別task-idを並行起動せず、会話中断後の状態確認にだけ`show`を一度使う。

## 失敗処理

| 状況 | 処理 |
|---|---|
| 接続失敗、DNS・TLS error、connection reset、rate limit、5xx、timeout、最終応答欠落 | 1回の応答失敗とする。新しいtask-idで1回だけ再試行し、合計2回失敗したら上位モデルが引き継ぐ |
| `OPENROUTER_API_KEY is not set`、HTTP 401、`invalid API key`、`authentication failed`など | 明示的な認証失敗は再試行せず上位モデルが直ちに引き継ぐ。403や単なる非zero statusから認証失敗を推測しない |
| 予算超過、ZDR非対応、依存command欠落、参照先欠落 | 応答失敗に数えず停止する |
| 機械的検出modeの失敗 | 上位モデルへ検出を切り替えず、品質ゲートを失敗にする |

上位モデル相当のAgent / subagentを利用できる場合、調査は読み取り専用、実装は許可パス限定で優先する。利用できなければオーケストレーター自身が担当する。

成功時も自己申告ではなく`result.json`、`report.md`、必要なら`candidate.patch`を確認する。`status != 0`または`timed_out: true`の候補patchは診断専用とする。
