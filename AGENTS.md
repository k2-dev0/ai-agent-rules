## HTTP Request
- サンドボックス外で行うこと

## メインモデルの選択

- ユーザーの明示指定を優先する。それ以外は依頼開始時、初期調査後の実装前、前提変更後、指摘の修正前に、残る判断と実装難度で選ぶ。上位の条件を優先し、方針確定だけでは下げない
- Luna / max：採用方針、変更対象pathと影響caller、不変条件、検証test・commandが確定し、残作業が削除、rename、移動、参照追従、literal置換、既存実装への置換、複数fileの完全に同型な修正だけ。新しいproduction logic・分岐・data変換・状態遷移・error処理・caller調整・testシナリオ実装を含まない
- Sol / high：方針確定後でも、新しいproduction logic・分岐・data変換・状態遷移・error処理・caller調整・testシナリオ実装が残る。または公開API、互換性、責務境界、data・error契約、UI表示・操作・状態遷移に新しい選択が必要
- Astra / high：仕様・責務・影響範囲の組み直し、並行実行・保存・再処理の整合性判断、既存検証では重大な見落としが残る
- 独立コードレビューの成立する`critical`・`high`指摘が1件でもあれば、修正前にLunaからSol、SolからAstraへ上げる。修正後HEADのレビューで`critical`・`high`がなくなるまで下げない。`medium`・`low`は昇格せず、修正するかユーザーへ確認する
- 選定したモデル・effortが現在値と異なる場合だけ `[skills_root]/MODEL_SWITCH.md` を読み、切り替える。一致する場合は読まない。文脈圧縮、会話の長さ、以前の読了記憶は読込条件にしない
