# DeepSeek worker

Codexから`deepseek-worker` MCPの`start_task`・`wait_task`・`continue_task`・`abort_task`を使う。bridge本体・DSH依存・privacy・session保存は別repository `deepseek-bridge`の責務。初期commitを比較元にでき、4 toolが利用可能であることを確認する。tool定義は初期表示から省略される場合があるため、初期表示だけで未提供と判断しない。`ALL_TOOLS`を`deepseek`で検索し、返された正確なtool名から4操作を解決する。4操作が実行時registryにない、bridgeの起動失敗、MCPの入出力契約不一致なら依存作業を止め、観測した検索結果・errorだけを報告する。workerの最終報告違反`task_contract_error`は下記の失敗後手順で扱う。

## 依頼

初回briefはDeepSeek workerへの実装または検証依頼と明記し、目的、確定した設計・シナリオ、対象、受入条件、検証方法、必要な規約pathだけを渡す。変更禁止箇所はtask固有の指定がある場合だけ加える。全会話・コード全文・秘密を転送せず、正本のpathを渡す。先行するshell process・reviewerが完了してから起動する。

親が確認済み事実、変更範囲、不変条件、関連test・検証commandを確定してから渡す。workerは対象と直接依存を実装に必要な範囲で読み、新しい調査、範囲拡張、設計判断が必要なら`needs_decision`で親へ返す。実行中は親が編集・Git変更・reviewer起動をしない。

1. `start_task({"brief":"...","title":"..."})`で返されたtask ID・session IDを保持する
2. `wait_task({"task_id":"..."})`を1回呼び、完了・判断待ち・失敗のterminal結果まで待つ；途中経過の取得・再poll・実況を行わない
3. `completed`／`needs_decision`で同じ実装方針を続ける場合だけ`continue_task({"task_id":"...","message":"差分指示"})`を使う
4. 目的・設計の変更、failed／aborted／interrupted後は実差分を確認し、必要なら残作業でfresh taskを作る；旧taskの実行停止を確認できるまでは編集・新規起動しない

`wait_task`が`running`を返す、またはclient timeoutになる場合は停止未確認として再poll・新規起動せず報告する。停滞・hard timeout・runtime回収はbridgeのwatchdogへ任せ、親は独自の進捗監視を追加しない。経過時間や無出力だけで取消・再起動しない。活動通知は定期heartbeatではなく、長いtool処理では途絶え得る。無活動期限はbridgeで管理し、MCPの待機期限とは分ける。

`task_contract_error`でも、一致するtaskのterminal結果とhookの保護解除を確認できればbridge利用不能とは扱わない。親が実差分・必要な検証結果を照合し、未確認の成功報告は採用せず、残作業をfresh taskへ渡す。failed taskへ`continue_task`しない。停止未確認、`abort_error`、保護残存時は編集・新規起動せず報告する。

変更要求が実行中に届いたら、旧指示を止める必要がある場合は`abort_task`を呼び、停止確認後に差分を照合する。取消受付・timeoutを停止完了とみなさず、worktreeを自動復元しない。

完了報告は変更概要、実行command・終了結果、未実行・未解決、質問を受け取る。報告だけで検証済みにせず、親が差分範囲と実行結果を照合する。大きなログは必要な部分だけ読む。同じ設計の確認・修正はsessionを継続し、親の調査結果を渡し直さない。

## workerの担当

workerとして呼ばれた場合は依頼brief、[実装基準](IMPLEMENTATION_RULES.md)、対象規約に従う。`AGENTS.md`の親向け委譲・モデル切替・reviewer起動は実行せず、自分へ再委譲しない。

- 渡された設計・シナリオに従い、test・production codeの編集、検証・整形を行う
- 未確認事実・診断のscope分類・原因調査・新しい設計判断が必要なら、推測や探索で補わず`needs_decision`を返す
- 既存のユーザー変更と変更禁止箇所を保持する；範囲拡張・設計変更・公開契約の選択が必要なら停止して親へ返す
- Gitの読み取りは可；stage・commit・branch・reset・rebase、agent設定・hook状態の書き込みは親へ返す
- 固定scriptが保護状態を書き込むbaseline・完了mark等も親が実行する
- 認証情報、外部公開・deploy・課金・message送信の判断を代行しない
- 最終報告はbridge指定のJSON契約だけを返す。独自キーを追加せず、未解決事項は`unresolved`へ入れる。送信前に必須キー・型・長さを照合する

TDDのRed確認で一度返却し、親のtest commit・baseline後にGreenへ進む。正常終了時は同一sessionを継続し、failed時は上記の失敗後手順を使う。修正指摘は渡された箇所だけを変更する。Astra担当箇所と共通依存に衝突する場合は勝手にまとめて直さず親へ返す。
