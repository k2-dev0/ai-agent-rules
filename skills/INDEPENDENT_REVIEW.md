# 独立レビューの起動・結果処理

本体コードの変更開始前に開始HEADを`review_base`として保持する。テスト追加・修正も対象に含め、実装前baselineで上書きしない。既存の変更をレビューする依頼では指定された比較元を使い、不明なら確認する。

必要なtest・静的検査・整形・polish、commit後、完了報告前に実行する。メインによる全差分の自己レビューは工程に含めない。ネスト検出だけで代用しない。

## 対象・入力

1. `git rev-parse HEAD`を`review_head`として固定する。両SHAの存在、`git merge-base --is-ancestor <review_base> <review_head>`、追跡fileの未commit変更がないことを確認する。比較元を直前のcommitへ縮めない。
2. briefはrepository絶対path、両SHA、元の要求・制約の本文または正本pathだけ。実装経緯・採用理由・自己評価・過去のレビュー結果・会話履歴を渡さない。会話中の要件は意味を変えず必要部分だけ抜き出す。
3. 差分全体を対象にする。ignored / untrackedの検証資産を含められない場合は未確認範囲として明示し、検証済みと扱わない。

## 起動・待機

| 環境・条件 | role | model / effort |
|---|---|---|
| Codex・通常 | `code-reviewer` | Sol / high |
| Codex・[モデル選択](MODEL_SELECTION.md)のAstra条件に該当する検証 | `deep-reviewer` | Astra / high |
| Claude | `code-reviewer` | Opus / high |

Codexは`agent_type`にroleを指定し、`fork_context: false`または`fork_turns: "none"`を明示する。Claudeは`subagent_type`にroleを指定する。model・effortは専用定義を使い、起動引数で上書きしない。

[子・待機の規則](SUBAGENT_RULES.md)に従って新規の読み取り専用agentを1体起動し、メインは完了まで作業を止める。完了後は子を終了・解放する。対応role・起動toolが利用不能、起動拒否、中断、入力不足なら独立レビュー未完了と報告する。メインの自己確認で代用しない。

## 結果・修正

終了時のHEADと追跡fileの状態が開始時と違えば結果を完了判定に使わず、変更内容を確認して対象を固定し直す。最終結果だけ取得し、中間ログは読まない。

- `reviewed`：両SHAと全差分の確認が一致した場合だけ受理する。未確認範囲がなく、全指摘が修正済みまたは根拠付きで却下済みなら独立レビュー完了。
- 指摘あり：メインが根拠を確認し、採用・却下を判断する。採用分は[修正ループ](VERIFICATION_FLOW.md#修正ループ)に従い、必要なpolish・commit後、同じ`review_base`と新HEADを新規の子へ渡す。
- `incomplete`・対象不一致・未確認範囲あり：指摘なしとして扱わず、未解決事項を報告する。

同一のHEAD・要求・制約で確認済みの結果は再利用し、同じ入力で繰り返し起動しない。却下した指摘は根拠を短く残す。要件・制約が変わった場合は再レビューする。
