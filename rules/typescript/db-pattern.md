# DB スキーマの編集ルール

## 全体方針

1. ORM やデータソースはプロジェクトの方針に合わせること。以下のPrisma・MySQL系の例は該当する構成だけに適用し、既存schema・単位・mappingを確認する。他のproviderへnative型を持ち込まない。

## 命名ルール

| 対象 | 命名・mapping |
|---|---|
| model名 | PascalCaseの英語名。例: `Contract`、`CustomerInvoice` |
| 既存table名とmodel名が異なる場合 | `@@map()`で明示 |
| application管理tableのfield名 | camelCase。`@map()`は付けない |
| 外部DB同期tableのfield名 | camelCaseで定義し、元column名を`@map()`でmapping。例: `shotNo String @map("shot_no")` |
| relation名 | 関連modelの意味を表すcamelCaseの英語名。同一modelへの複数relationは`@relation(name: "...")`で区別 |

## 型定義

| data | 型・制約 |
|---|---|
| 通常の文字列 | `String @db.VarChar(n)`で最大長を明示 |
| 上限が大きい可変長text | `String @db.Text` |
| 日付 | `DateTime @db.Date` |
| 日時 | `DateTime @db.DateTime(0)`または`DateTime @db.Timestamp(0)` |
| 金額 | 単位と必要精度を確認し、整数の最小通貨単位または精度・scaleを定めた`Decimal`を既存契約に合わせて使う。`Float`は二進浮動小数点の丸めを伴う。`Decimal`を同じ理由で禁止しない |
| 構造化data | `Json @db.Json`。検索・filter対象は正規columnとして定義 |

## 主キー・一意制約

1. 外部DB同期テーブルは外部DBの業務番号をそのまま `@id` にすること
2. アプリ管理テーブルは `Int @id @default(autoincrement())` を使用すること
3. マスタ/ステータステーブルはコード文字列を `@id` にすること
4. 明細テーブル等の複合主キーは `@@id([field1, field2])` で定義すること
5. 主キー以外で一意性を保証するフィールドには `@@unique()` を使用すること

## リレーション設計

1. 外部キーフィールドとリレーションオブジェクトを分けて記述すること
  - 例: `contractNumber String?` + `contract Contract? @relation(...)`
2. 1対多は親モデル側に子モデルの配列フィールドを定義すること
3. 多対多で関係自体の属性・制約が必要なら、明示的な中間テーブルで管理する
  - relation自体の属性・制約が必要な場合に使う。単純な関係は既存方式を維持し、将来の可能性だけで中間modelを増やさない
4. 外部キーが任意の場合はリレーションフィールドを Optional（`?`）にすること

## ステータス・マスタ管理

1. ステータスは専用モデルで管理し、以下の共通フィールドを持たせること
  - `id String @id` — ステータスコード
  - `name String @db.VarChar(255)` — 表示名（`@@unique([name])`）
  - `order Int` — 表示順
  - `createdAt DateTime @default(now())`
  - `updatedAt DateTime @updatedAt`

## インデックス設計

1. 検索・結合に頻繁に使用される外部キーカラムには `@@index()` を付与すること
2. 複合一意制約で代用できる場合は `@@unique()` で兼ねること

## コメント規約

1. 全フィールドに `///`（トリプルスラッシュ）で日本語コメントを付けること
2. モデル定義の直前に `///` で業務上の意味を記載すること
3. 非推奨フィールドには `@deprecated` をコメント内に明記し、代替フィールドを案内すること

## 同期メタデータ

1. 外部DB同期テーブルには同期日時フィールドを持たせること。元columnが`sync_at`なら、fieldは`syncAt DateTime? @map("sync_at")`とし、上のcamelCase規約と揃える。`sync_reply_at`も同様にmappingする。
2. アプリ管理テーブルには `createdAt DateTime @default(now())` と `updatedAt DateTime @updatedAt` を必ず付与すること
