# 入力検証・schema

共通基準は`[skills_root]/IMPLEMENTATION_RULES.md`に従う。

- 対象packageの依存・既存schemaに合わせてlibrary・定義方式を選ぶ
  - schema object用の`schema.ts`に手書き検証関数を置かない
- 必須選択・placeholderあり・初期値nullの全条件を満たすfieldは、同契約の既存utilityを再利用する
  - import・exportを確認し、存在を仮定しない
- 既存処理がなければ入力境界に必要なschemaだけを定義する
  - 将来用utilityは作らない
