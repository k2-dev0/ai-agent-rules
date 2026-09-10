# API編集

- 複数の書き込みを一体で成功・失敗させる場合は、既存方式のtransactionを使う
  - 基本はinteractive transaction
  - 単一の原子的書き込みは包まない
- sortは既存APIと要求に合わせる
  - 切り替えるcallerがなければsort引数・UIのreverseを追加しない
- 取得後のfilter()はWHEREで代替できれば移す
  - クエリが複雑になる場合はfilterを維持し、理由をコメントに残す
  - 必要ならテーブル設計を見直す
- DB条件・callerを調べ、挙動・性能のtrade-offが要件から決まらない場合だけ相談する
