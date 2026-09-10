# UI編集

- alias・export・同型実装を確認し、共通component入口を使う
  - ラップ済みlibraryを直接importしない
- 切り出しは`[skills_root]/IMPLEMENTATION_RULES.md`に従う
- 既存の拡張クラスを優先する
  - 動的なクラス結合は既存方式に合わせ、未導入のclassnames／clsxを追加しない
- 命名・責務は同型componentに合わせる
  - resource接頭辞の規約なら`BillPaymentDetail.tsx`のようにする
