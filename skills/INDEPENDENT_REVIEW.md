# 独立レビューの起動・結果処理

起動入力を組み立てる前に[子の起動手順](SUBAGENT_RULES.md)の未読分を読む。

変更前HEADはhookが`.[agent_name]/tmp/independent-review.<session_id>.json`の`base`へ保存する。現在sessionの状態を読み、`review_base`に使う。状態がなければ編集前に保持したHEADまたはユーザー指定の比較元を使い、不明なら確認する。現在HEADや直前の1commitを根拠なく比較元にしない。状態ファイルは直接編集しない。

メインによる全差分の自己レビューは工程に含めない。ネスト検出だけで代用しない。

## 対象・入力

1. `git rev-parse HEAD`を`review_head`として固定する
2. JSONの`repository`に絶対path、`review_base`・`review_head`に完全SHA、`requirements`に元の要求・制約の本文を入れる
   - Codexは`python3 .codex/hooks/shell/agent-input.py prepare <選んだrole> '<4キーJSON>'`を実行し、出力された引数を変更せず`spawn_agent`へ渡す
   - Claudeはこの4項目のobjectを1回serializeしたJSON文字列を`prompt`に入れ、自然文の前置き・code fence・wrapper objectを加えず、role指定は外側のtool引数に置く
   - 実装経緯・採用理由・自己評価・過去のレビュー結果・会話履歴を渡さない
   - 採点・モデル選択・切替手順はrequirementsへ含めない
   - 会話中の要件は意味を変えず必要部分だけ抜き出す
3. 差分全体を対象にする
   - ignored / untrackedの検証資産を含められない場合は未確認範囲として明示し、検証済みと扱わない

## 起動・待機

| 環境・条件 | role |
|---|---|
| Codex | `code-reviewer`（Astra / xhigh） |
| Claude | `code-reviewer` |

選んだroleで起動する。入力拒否は共通の起動手順に従って訂正し、実際に開始した子の完了後に終了・解放する。対応role・起動toolが利用不能、中断、入力不足を解消できない場合は独立レビュー未完了と報告する。メインの自己確認で代用しない。

## 結果・修正

終了時のHEADと追跡fileの状態が開始時と違えば結果を完了判定に使わず、変更内容を確認して対象を固定し直す。

指摘のラベルをそのまま採用せず、`condition`・`impact`・`evidence`を[重大度基準](REVIEW_SEVERITY.md)と照合してから以下へ進む。

- `reviewed`：両SHAと全差分の確認が一致した場合だけ受理する
  - 未確認範囲がなく、全指摘が修正済みまたは根拠付きで却下済みなら独立レビュー完了
- `critical`・`high`：メインが成立条件を確認する
  - 成立する指摘は[修正ループ](FIX_FLOW.md#修正ループ)を読んで修正する
  - 不成立なら根拠付きで却下する
- `medium`・`low`：`medium`、`low`の順で各指摘の先頭に通し番号を付け、成立条件と影響を示す
  - 「修正する番号を指定してください」と確認する
    - 例：`1,3`
    - 修正しない場合は`なし`
  - 回答前に修正しない
  - 指定された指摘だけ[修正ループ](FIX_FLOW.md#修正ループ)を読んで修正し、残りは却下として根拠を残す
- `incomplete`・対象不一致・未確認範囲あり：指摘なしとして扱わず、未解決事項を報告する

修正後の新規レビュー結果を直前の結果と比較し、同じfile内の関数・section・testへの指摘が再発した場合、Codexは[箇所ごとの修正担当](FIX_FLOW.md#codexの修正担当)、Claudeは[修正ループ](FIX_FLOW.md#修正ループ)の昇格条件を適用する。異なる部分の指摘は比較対象にしない。

同一session・HEAD・要求・制約で確認済みの結果は再利用し、同じ入力で繰り返し起動しない。却下した指摘は根拠を短く残す。要件・制約が変わった場合は再レビューする。

指摘の採否・却下根拠の妥当性はメインが判断する。レビュー未実施・未完了を、commit済み・tracked差分なしだけでタスク完了へ置き換えない。
