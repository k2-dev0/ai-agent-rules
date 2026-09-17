# DeepSeek worker

Codexから`deepseek-worker` MCPの`start_task`・`wait_task`・`continue_task`・`abort_task`を使う。bridge本体・DSH依存・privacy・session保存は別repository `deepseek-bridge`の責務。初期commitを比較元にでき、4 toolが利用可能であることを確認する。toolが未提供、起動失敗、契約不一致なら依存作業を止め、未接続と報告する。

## 依頼

初回briefはDeepSeek workerへの依頼と明記し、目的、調査のみ／編集可、対象、受入条件、必要な規約pathだけを渡す。変更禁止箇所・検証方法はtask固有の指定がある場合だけ加える。全会話・コード全文・秘密を転送せず、正本のpathを渡す。調査のみではfile・Git・外部状態を変更しない。先行するshell process・reviewerが完了してから起動する。

調査結果は確認済み事実の`path:line`、関連test・検証command、推論・未確認、必要な設計判断を求める。実装は確定した設計・シナリオだけ渡し、新しい判断は`needs_decision`で親へ返させる。実行中は親が編集・Git変更・reviewer起動をしない。

1. `start_task({"brief":"...","title":"..."})`で返されたtask ID・session IDを保持する
2. `wait_task({"task_id":"...","timeout_ms":60000})`で完了・判断待ち・失敗を受け取る；`running`は未終了だけを示し、正常動作・進捗の証拠にしない
3. `completed`／`needs_decision`で同じ実装方針を続ける場合だけ`continue_task({"task_id":"...","message":"差分指示"})`を使う
4. 目的・設計の変更、failed／aborted／interrupted後は実差分を確認し、必要なら残作業でfresh taskを作る；旧taskの実行停止を確認できるまでは編集・新規起動しない

各`running`応答の`last_activity_at`・`phase`・`progress`等、bridgeが返す実活動の指標を前回値と比較する。60秒待機を2回終えても実活動を確認できない、またはbridgeが活動を観測できない場合は停滞と扱い、同じ待機を繰り返さず`abort_task`で停止・回収する。停止結果と観測できなかった項目を一度だけ報告する。ユーザーが待機継続を明示した場合を除き、同じ`running`の実況を繰り返さない。

変更要求が実行中に届いたら、旧指示を止める必要がある場合は`abort_task`を呼び、停止確認後に差分を照合する。取消受付・timeoutを停止完了とみなさず、worktreeを自動復元しない。

完了報告は変更概要、実行command・終了結果、未実行・未解決、質問を受け取る。報告だけで検証済みにせず、親が差分範囲と実行結果を照合する。大きなログは必要な部分だけ読む。同じ目的の確認・修正はsessionを継続し、毎回再調査させない。

## workerの担当

workerとして呼ばれた場合は依頼brief、[実装基準](IMPLEMENTATION_RULES.md)、対象規約に従う。`AGENTS.md`の親向け委譲・モデル切替・reviewer起動は実行せず、自分へ再委譲しない。

- repository調査、診断、test・production codeの編集、検証・整形を行う
- 既存のユーザー変更と変更禁止箇所を保持する；範囲拡張・設計変更・公開契約の選択が必要なら停止して親へ返す
- Gitの読み取りは可；stage・commit・branch・reset・rebase、agent設定・hook状態の書き込みは親へ返す
- 固定scriptが保護状態を書き込むbaseline・完了mark等も親が実行する
- 認証情報、外部公開・deploy・課金・message送信の判断を代行しない

TDDのRed確認で一度返却し、親のtest commit・baseline後に同一sessionでGreenへ進む。修正指摘は渡された箇所だけを変更する。Astra担当箇所と共通依存に衝突する場合は勝手にまとめて直さず親へ返す。
