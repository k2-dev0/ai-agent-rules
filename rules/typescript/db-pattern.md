# DB schema編集

既存ORM・provider・schema・単位・mappingを確認する。Prisma／MySQLの記法は該当構成だけに使い、他providerへnative型を持ち込まない。

## 命名・型

| 対象 | 指定 |
|---|---|
| model | 英語PascalCase。既存table名と違えば`@@map()` |
| application管理field | camelCase、`@map()`なし |
| 外部DB同期field | camelCaseと元columnの`@map()` |
| relation | 関連modelを表す英語camelCase。同一modelへの複数relationは名前で区別 |
| 文字列 | `String @db.VarChar(n)`、大きいtextは`String @db.Text` |
| 日付 | `DateTime @db.Date` |
| 日時 | `DateTime @db.DateTime(0)`または`DateTime @db.Timestamp(0)` |
| 金額 | 既存の単位・精度に合わせ、最小通貨単位の整数またはprecision・scale指定のDecimal。Floatの丸めに注意し、Decimalを同じ理由で禁止しない |
| 構造化data | `Json @db.Json`。検索・filter対象は正規column |

## キー・relation

| 対象 | 指定 |
|---|---|
| 外部DB同期table | 外部の業務番号を`@id` |
| application管理table | `Int @id @default(autoincrement())` |
| master／status | コード文字列を`@id` |
| 複合主キー | `@@id([field1, field2])` |
| 主キー以外の一意性 | `@@unique()` |
| 頻繁に検索・結合する外部キー | `@@index()`。複合uniqueで兼用できれば追加しない |

外部キーfieldとrelation objectを分け、任意の外部キーはrelationも`?`にする。1対多は親に子の配列を定義する。多対多は関係自体に属性・制約が必要な場合だけ中間tableを使い、単純な関係は既存方式を維持する。

## 共通field・コメント

statusは専用modelで次を持つ。

- `id String @id`
- `name String @db.VarChar(255)`と`@@unique([name])`
- `order Int`
- `createdAt DateTime @default(now())`
- `updatedAt DateTime @updatedAt`

application管理tableにもcreatedAt・updatedAtを付ける。外部同期tableには同期日時を持たせ、元columnに合わせて`syncAt DateTime? @map("sync_at")`等を定義する。sync_reply_atも同様。

model直前と全fieldに日本語の`///`コメントを付ける。非推奨fieldは`@deprecated`と代替fieldを示す。
