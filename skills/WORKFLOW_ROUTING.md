# Codexの作業分担

Codexの親だけが読む。ユーザーのモデル指定を優先し、指定と工程の必要モデルが競合する場合は黙って切り替えない。Claudeは従来の`MODEL_SELECTION.md`に従う。

## 動線

| 条件 | 親・レビュー |
|---|---|
| 説明・進捗確認 | Sol / high。必要なrepository調査も親が行う |
| 変更内容が一意で、挙動・公開契約・保存形式を変えない機械的変更 | Sol / highで受付・差分範囲と検証結果の確認・Git・報告。独立レビューは要求された場合だけ |
| 設計判断、挙動・公開契約の変更、TDD、設計書作成 | 主担当Sol / highが調査・設計・受入条件を確定。実装後は独立Astra reviewer |
| レビューだけの依頼 | 親Sol / highが専用Astra reviewerを起動 |

private symbolのrename・typo・整形でも、外部consumer、動的参照、serialization、DB、設定keyへ影響するなら設計判断へ戻る。file数だけで分類しない。調査結果が不足する場合は親が追加調査する。

repository調査・原因診断・診断のscope分類は親が行い、確認済み事実・変更範囲・不変条件・検証方法を保持する。test作成・実装・通常修正・検証・整形は[DeepSeekの実行](DEEPSEEK_WORKFLOW.md)に従う。workerが未確認事実や新しい設計判断を必要とした場合は親へ返し、親が追加調査して同じ正本を更新する。workerへ調査全体を再委任しない。

設計文書は親が編集する。production code・testの親による修正は[再指摘箇所への介入](FIX_FLOW.md#codexの修正担当)またはユーザーの明示指定に限る。bridge利用不能を理由に親実装・別runnerへ自動代替しない。

## モデル・effort

通常・調査・設計は主担当`gpt-5.6-sol` / `high`。設計監査・実装レビューは`gpt-6-astra` / `medium`とし、critical検出後もeffortを上げない。再指摘箇所の直接修正は[修正担当](FIX_FLOW.md#codexの修正担当)に従いAstra / mediumへ切り替える。難度採点によるモデル振り分けは行わない。

現在値が担当工程の選定値と違えば[切替手順](MODEL_SWITCH.md)の未読分を読み、先行tool・worker・reviewer・承認の完了後に`switch_model`だけを呼ぶ。受付だけでは進まず、適用結果と実際のmodel・effortを確認する。再指摘箇所の直接修正後はSol / highへ戻す。

## 完了

worker停止後、親が変更範囲・ユーザー変更の保持・実検証結果を照合し、1ファイルずつstage・commitする。設計を伴う変更・TDD・明示レビューは[独立レビュー](INDEPENDENT_REVIEW.md)を完了する。未実行・未確認・未解決を成功に含めない。
