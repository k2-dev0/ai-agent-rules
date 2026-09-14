# メインモデルの選択

変更を伴う依頼だけに使う。説明・調査だけなら現在モデルで行い、ユーザー指定があれば評価せず指定を使う。

1. 現在モデルで調査し、変更範囲・整合性条件・検証方法を含む実装方針を確定する
2. テストを含む最初の編集前に`difficulty-evaluator`へ`{"repository":"<絶対path>","implementation_policy":"<実装方針>"}`だけを渡す
   - Codexは`spawn_agent`の`message`へこの2キーだけのobjectを1回serializeしたJSON文字列を入れ、`task_name:"difficulty_evaluator"`と`fork_turns:"none"`は外側のtool引数に置く
   - `message`に前後の説明、code fence、wrapper object、追加keyを含めず、`task_name`と`fork_turns`も入れない
   - `implementation_policy`はJSONデコード後4000文字以内にまとめる
   - 方針に背景・会話・採用理由・主担当の調査結果・難度予想・設計書参照・モデル情報・選択基準を含めない
3. 成功形式の`score`と`reason`だけのJSONを受け取り、1〜3はLuna / max、4〜7はSol / high、8〜10はAstra / xhighを選ぶ
4. 選定値が現在値と異なる場合は、他のtool・子・承認をすべて完了し、次の応答で`switch_model({"model":"モデルID","config":{"effort":"思考量"}})`だけを呼び、対応する`PreModelSwitch`がない環境だけ呼出前に[切り替え手順](MODEL_SWITCH.md)を読む

`{"error":"..."}`（入力エラー）・`null`・形式不正・範囲外・空の理由・起動不能は難度評価の失敗であり、正常終了・評価済みとして扱わない。自己判断の点数で続行せず、依存する編集を止めて失敗原因を報告する。同じ子への追送で完了扱いにせず、入力・契約・起動経路を直した後にfreshな`difficulty-evaluator`を新規起動する。成功した方針・点数・理由は保持し、同じ方針の修正・再開では再利用する。変更範囲・整合性条件・検証方法を含む方針が変わる場合だけ、依存する編集前に再評価する。

切替toolがない、またはhook到達前に入力・model・effort・実行状態を拒否された場合、ユーザー指定と必要な昇格は依存する編集を止め、降格だけなら選定値と失敗を報告して現在モデルで続ける。他作業の待機だけが理由なら完了後に同じ要求を一度再試行する。
