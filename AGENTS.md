## HTTP Request
- サンドボックス外で行うこと

## メインモデルの選択

- ユーザーの明示指定を優先する。それ以外は現在モデルで調査・実装方針の決定まで行い、テストを含む最初の編集前に専用`difficulty-evaluator`へ難易度調査を依頼する。説明・調査だけの依頼では起動しない
- 起動前に`[skills_root]/SUBAGENT_RULES.md`に従う。briefは`repository`（絶対path）と`implementation_policy`（確定済み実装方針の本文）だけのJSON文字列。背景、会話、採用理由、主担当の調査結果・難度予想、設計書への参照を渡さない。Codexは`agent_type: "difficulty-evaluator"`と`fork_turns: "none"`、Claudeは`subagent_type: "difficulty-evaluator"`。model・effortは専用定義を使う
- `evaluated`かつ`unchecked: []`の最終結果から選定値を使う。入力不一致・不正な結果・`incomplete`・起動不能なら編集を止めて報告する。方針と評価結果を保持し、同じ方針の修正・再開では再利用する。方針・変更範囲・整合性条件・検証方法の変更が必要になった場合だけ、現在モデルで方針を更新して依存する編集前に再評価する。会話の長さ・圧縮・工程の移行だけでは再評価しない
- 独立コードレビューの成立する`critical`・`high`指摘が1件でもあれば、修正前にLunaからSol、SolからAstraへ上げる。修正後HEADのレビューで`critical`・`high`がなくなるまで下げない。`medium`・`low`は昇格せず、修正するかユーザーへ確認する
- 選定したモデル・effortが現在値と異なる場合だけ `[skills_root]/MODEL_SWITCH.md` を読み、切り替える。一致する場合は読まない。文脈圧縮、会話の長さ、以前の読了記憶は読込条件にしない
