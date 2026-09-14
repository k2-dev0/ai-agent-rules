# サブエージェント

- 子の用途は実装方針確定後の難易度調査（`difficulty-evaluator`）、独立コードレビュー（`code-reviewer` / `deep-reviewer`）、設計監査（`design-reviewer`）、ネスト候補抽出（`nesting-reviewer`）
  - 方針決定のための一般調査・実装・修正はメインが行う
- 子は1体ずつ新規起動し、サブエージェントの完了までメインの作業を止め、完了確認後に次へ進む
- 現在の環境の専用roleの定義と起動toolを確認してから起動する
  - `agent_role`が空の汎用子、`task_name`やnicknameだけの子を専用roleの代用にしない
  - 専用roleを渡せない起動toolしかない場合は子を起動せず、停止して報告する
  - 起動失敗を別環境の子で代替しない（未登録なら同じ環境の配置、入力拒否なら入力契約を確認）
- Codexは`agent_type`と`fork_context: false`または`fork_turns: "none"`、Claudeは`subagent_type`でroleを指定する
- 各roleの入力契約に従ってbriefを渡す
  - コード・規約は正本を参照させる
- 子の結果は最終結果だけ受け取り、全文ログ・中間出力を再取得しない
- サブエージェントの完了通知または60秒以上の待機を使う（tool・上位指示の上限まで）
  - 返却cursorがあれば次回へ渡す
- 即時snapshotは初回確認か新しい事実の確認に限る
  - 進展なしの短周期poll、同じ結果の再読、催促、待機だけのモデル交代は禁止
  - 完了を受けたら元の作業を続ける
