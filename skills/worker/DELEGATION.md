# worker委任の共通契約

workerを呼ぶskillはこの文書を全文読んでから実行する。個別skillは対象と必須成果を決め、この文書は実行、証拠、時間、結果判定、再試行を決める。重複する説明を個別skillへ書かない。

各workflowはsession最初の委任前に`bash [skills_root]/worker/delegate.sh prepare`を実行する。初回はhookがこの文書を注入して停止する。内容を反映して`prepare`を再実行し、同じworkflowの後続委任では繰り返さない。

## 責務

| 担当 | 責務 |
|---|---|
| worker | 読み取り調査、根拠範囲の選択、許可pathの初回実装候補 |
| `delegate.sh` | 隔離実行、timeout、最終応答分類、snapshotからの証拠抽出、patchとmetadataの保存 |
| 上位モデル | 依頼項目の確定、証拠と要求の対応判断、候補採否、補完・fallback、修正・テスト・Git |

固定実行器より先または実行中に同じ仕事をAgent / subagentへ並行委任しない。複数workerのdata、state、cache、config、tmpはtaskごとに分離する。

## モデル非依存のworkflow

上位モデルのfamily、性能tier、effort、context量を理由に、workerへの依頼形式、必須成果ID、claim-evidence形式、成功条件、再調査条件、直接調査の例外、retry回数を変えない。高性能・高effortでも独自に広域調査せず、低性能・低effortでも必須工程を省略しない。差が出てよいのは、検証済み証拠からの推論、重要度、採否、ユーザーへの説明だけとする。

fallback modelへ切り替える場合も同じrequest digestの依頼を使う。依頼不足を修正した場合は別requestとしてdigestを変え、変更した必須成果IDと理由を残す。モデル名に応じた隠れたprompt追加や工程分岐を作らない。

workerはOpenRouterを使い、既定モデルは`minimax/minimax-m3`とする。別モデルは`DELEGATE_MODEL=openrouter/<provider>/<model>`、必要なvariantは`DELEGATE_MODEL_VARIANT=<variant>`で明示する。skill名、実行path、結果namespaceへprovider名やモデル名を入れない。

## 依頼

依頼は目的、scope、必須成果を短く書く。必須成果は`O1`、`O2`のような固定IDを付ける。識別子、path、数値、固有名詞を省略・翻訳しない。曖昧な「詳しく」「適切に」「必要なら」だけで完了条件を表さない。

初回調査は各必須成果について、対象symbolの定義だけでなく、直接のcaller・callee、分岐・return・await、関連test、設定・runtime境界のうちclaim成立に必要な範囲までworkerに辿らせる。上位モデルは調査pathを作るためにproduction fileを読まない。`survey`へproduction pathを渡す必要はなく、ユーザー入力、設計書、既知の識別子・機能語を探索anchorとして渡す。正確なpathを含めるのは、ユーザー入力、設計書、過去の検証済みevidence、変更一覧ですでに判明している場合だけとする。

`implement`には設計書、Red要約、許可pathを必ず渡す。

```bash
bash [skills_root]/worker/delegate.sh implement <時間引数> \
  <task-id> <設計書path> \
  --red-summary "command=<実行command>; failure=<期待した理由での失敗要約>; scenarios=<承認済み項目ID>" \
  -- <許可path>...
```

`errand`の実装指示には承認済みシナリオIDとRed要約を含める。request本文は保存せず、実効promptのdigestだけを`result.json`へ残す。機密情報をtimeout理由やtask-idへ含めない。

## 証拠

`survey`と`research`のworkerは事実ごとに`C1`、`C2`へ分け、各claimへ次を返す。

```markdown
### C1
Claim: <確認した事実を一つ>
Evidence:
- `repository相対path:開始行-終了行`
Interpretation: <コードがclaimを支える理由>
Limitations: <確認できない範囲。無ければnone>
```

workerはコード本文を貼らない。実行器がworkerと同じsnapshotから指定範囲と前後8行の行番号付きコードを`evidence.md`へ抽出し、revision、blob hash、指定範囲、展開範囲を`result.json`へ記録する。範囲外、symlink、Git・env、過大範囲、根拠のないclaimは失敗にする。

否定的なclaimは、調べたscope、完全一致の検索語、関連語、除外した候補、未調査範囲も`Interpretation`と`Limitations`へ書く。複数fileのdata flowや実行順序は、入口、呼び出し先、分岐・return・awaitを判断できる複数の根拠へ分ける。

上位モデルは`evidence_status: verified`で、対象fileの現在のblobが記録値と一致し、codeがclaimを直接支える場合、同じ箇所を再読しない。情報不足では、欠落したclaimまたは必須成果ID、既存evidenceで足りない理由、追加で辿る境界を明記し、`--supplement-of <前task-id>`を使って限定surveyを行う。初回を1回目として補完は2回まで、合計3回に固定する。前回workerの結論を根拠として渡さず、検証済みevidence IDだけを探索anchorにする。同じdigestの再送はせず、各補完で不足IDまたは探索境界を一つ以上追加する。追加対象を特定できなければ広域調査へ逃げず、未確認事項として停止する。保存済みsnapshotの範囲不足、branch・caller・callee・設定・runtime根拠の不足、claim同士の矛盾は、3回目までは直接調査の理由にしない。

上位モデルが調査目的でproduction fileを直接確認してよいのは次だけとする。実行前に該当理由と、再surveyより直接確認の方が有利な理由を一文で残す。

- API key未設定、HTTP 401、invalid API key、authentication failedなど明示的な認証失敗
- 通信、timeout、`missing_report`、`malformed_report`、`partial_report`が同じ依頼で合計2回失敗
- 情報調査が初回と補完2回の合計3回に達しても、特定した必須情報が不足
- worker snapshotに入らない未コミット状態、生成物、runtime・外部状態が対象
- security、認可、データ破壊など独立確認そのものが必要な高リスク判断
- ユーザーが上位モデル自身の確認を明示した

直接確認でもfile全体をReadへ渡さない。`evidence.md`の展開範囲を使うか、既知のpathと行範囲だけをrange指定可能な読み取り手段で取得する。path発見のためのRead、関連しそうという理由だけの周辺file探索、同じfileの先頭からの再読は禁止する。workerが利用不能になり共通契約のfallbackへ移る場合も、保存済みevidenceと検索anchorから始める。

workerの実装候補がpublishされた後の候補採否、修正、test failureの診断では、上位モデルは`candidate.patch`、変更対象、関連testを読める。これは調査fallbackではなく上位モデルのreview責務である。候補にないproduction pathへscopeを広げるための探索には使わない。

「念のため」だけで同じfileを再読しない。

## CLIと時間

`survey`、`research`、`implement`、`errand`、`nesting`は次をこの順で指定する。同じ依頼の通信再試行では`--retry-of`、情報不足を補う`survey`または`research`では`--supplement-of`を時間引数の後へ加える。二つを同時に使わない。

```bash
bash [skills_root]/worker/delegate.sh <mode> \
  --hard-timeout-minutes <2..60> \
  --idle-timeout-seconds <30..900> \
  --poll-seconds <2..60> \
  --timeout-reason "scope=<対象>,difficulty=<low|medium|high>,basis=<根拠>" \
  [--retry-of <前task-id> | --supplement-of <前task-id>] \
  <mode固有引数>
```

通常値は次を下回らない。ユーザーが短い上限を明示した場合だけ短縮する。timeout後は維持または延長する。

| difficulty | hard | idle | poll |
|---|---:|---:|---:|
| `low` | 30分 | 600秒 | 30秒 |
| `medium` | 45分 | 900秒 | 30秒 |
| `high` | 60分 | 900秒 | 30秒 |

実行器はidle内に3回以上のpoll、hard内に2区間以上のidle、24文字以上のreasonと`scope=`、`difficulty=`、`basis=`を要求する。pollはprocess生存、出力byte、有効JSON event、最後のevent種別を確認する。有効JSON eventだけがidleを更新し、同じeventの反復もhard timeoutを延長しない。実ログに基づく安全な判定ができるまで、path数など推測的な「意味的進捗」をkill条件にしない。

`smoke`は固定疎通確認であり、ユーザーが明示許可した場合だけ実行する。完了・中断結果は`bash [skills_root]/worker/delegate.sh show <task-id>`で再表示する。実行中の結果有無を`find`や`ps`で推測しない。

## 結果と再試行

成功条件は`status: 0`、`report_status: complete`、`output_contract_status: valid`、`outcome: fulfilled`であり、読み取り調査ではさらに`evidence_status: verified`を要求する。`worker-result`、`report.md`、`evidence.md`、実装時の`candidate.patch`を確認する。workerの自己申告だけで成功としない。

標準出力は上位モデルのcontextを守るためartifactごとに上限を持つ。省略時は完全なartifact pathを必ず表示する。省略は表示だけに適用し、`report.md`、`evidence.md`、`candidate.patch`、`opencode.jsonl`を削除・短縮しない。

| failure class | 処理 |
|---|---|
| 接続失敗、DNS・TLS、reset、rate limit、5xx、timeout、`missing_report`、`malformed_report`、`partial_report` | 同じ依頼を新task-idと`--retry-of`で1回だけ再試行する。合計2回失敗したら上位モデルが引き継ぐ |
| `invalid_output`、`invalid_evidence`、`incomplete_outcome` | 欠落claimまたは必須成果IDだけを具体化して新task-idで補完する。前回の未検証結論を事実として渡さない |
| API key未設定、HTTP 401、invalid API key、authentication failed | 再試行せず直ちに上位モデルへ切り替える |
| 予算超過、ZDR非対応、依存command欠落、参照先欠落 | 再試行せず停止する |
| `nesting`失敗 | 自力検出へ切り替えず品質ゲートを失敗にする |

モデル変更は曖昧な依頼の代替にしない。依頼を修正しても同じinstruction不履行が続き、費用とfallback modelが明示されている場合だけ使う。切替後も依頼とworkflowを変えない。候補返却後の通常レビュー・修正はworkerへ戻さず上位モデルが行う。非zeroまたはtimeout時のpatchは診断専用とする。

`--retry-of`はrequest digestの一致を、`--supplement-of`はdigestの変更と`information_attempt <= 3`を実行器が強制する。通信再試行は情報調査回数を増やさない。上位モデルのfamily、tier、effortで上限を変えない。
