# cowlick設計書形式

`draft` modeはこの文書を全文読み、次の形式を崩さない。

## ファイル構成

`draft-prompt/`には次だけを置く。

| ファイル | 契約 |
|---|---|
| `.prompt.md` | 実装順の`- [ ] branch-<機能名>-prompt.md`だけを並べるindex |
| `branch-<機能名>-prompt.md` | 1機能の自己完結した設計書 |

機能名はbranch名に使えるASCII kebab-caseとする。全項目を未完了で作り、`[x]`への変更は`tdd`の`from-prompt` modeだけが行う。依存される機能を先に並べる。

1設計書はおおむね1 branch、squash後の1 commitとする。APIとvalidation schema、migrationとschema変更、helper・定数とその利用箇所、テストと対象実装は同じ設計書へ置く。UI componentはcomponent単位で分ける。

## 設計書の必須section

````markdown
# <機能名>

## Summary
<目的と利用者に見える結果を1〜2行>

## Changes
```typescript
// <対象ファイル>
<日本語を含む構造化疑似コード>
```

## 対象ファイル
- @<相対パス>

## 参照ルール
- @.[agent_name]/rules/<関連rule>

## 完了条件
- <この1枚だけで判定できる条件>
````

Changesの疑似コードは次の言語規則に従う。複数行へ該当する場合は表の上を優先する。

| 書き方 | 対象 | 例 |
|---|---|---|
| 実名を保持 | 既存symbol、schema field、file pathも参照を壊さないよう実名を保持する | 既存コードにある関数名、`customer_no`、`src/service.ts` |
| 英語 | 予約語・演算子・構文、組み込み型と組み込みobject。標準library・外部library・frameworkのAPI、instance method・property名を英語で書く | `export`、`async`、`function`、`if`、`for`、`const`、`Promise`、`.map()`、`.length` |
| 日本語 | 新しく設計する業務上の関数、引数、変数、型、結果field、error名、処理内容は日本語で書く | `利用内容を確定する関数`、`使用件数`、`保有件数超過` |

分岐とloopは文章へ畳まず構文で示す。error処理とDB書き込み、メール、外部APIなどの副作用は一つずつ書き、行数削減のために省略しない。実装時の新しい英語識別子は固定しない。

Changesは、実装者が挙動を再設計せずコードへ変換できる密度で書く。対象に応じて次を疑似コードへ含める。

- 関数: `export` / local、同期 / `async`、引数、guardの評価順、導出値と計算式、正常結果と区別可能なerror、返却field
- validation schema: `null`を含む入力形状、条件付き必須、形式条件、clientで検証する範囲とserverの最新dataで再検証する範囲
- DB / API: 認証主体、`where`の全条件と日付境界、`orderBy`とtie-break、正とするdata、再取得・再検証、選択方法、公開するfield
- 副作用: DB更新、メール、外部APIの実行順、field mapping、`await`、失敗時の扱い
- 共通要素: 定数・配列の形、直接のconsumer、別の値から導出する上限などの関係

「検証する」「取得する」「errorを返す」だけで済ませず、判定条件、取得条件、errorの区別を展開する。同じ処理を複数対象へ適用する場合は`for (対象 of [...])`へまとめてよいが、共通処理を省略せず、対象固有の差だけを別に示す。

圧縮してよいのは重複説明と同一の外枠だけとする。guard順、条件式、境界の等号、計算式、sort・tie-break、正常・errorの返却field、状態遷移、副作用、dataの権威を文章一行へ畳まない。Summaryや完了条件でChangesを重複説明しない。

次は書式と密度の例であり、この処理自体を要件として流用しない。

```typescript
// service.ts
import { 既存の送信関数 } from "./既存経路"

export async function 利用内容を確定する関数(使用方法, 入力件数, 候補一覧, 上限件数) {
  if (使用方法 === null) {
    return { 成功: false, エラー: "必須選択" }
  }

  const 使用件数 = 使用方法が全件使用
    ? Math.min(候補一覧.length, 上限件数)
    : 入力件数

  if (使用件数 > 候補一覧.length) {
    return { 成功: false, エラー: "保有件数超過" }
  }

  const 使用候補一覧 = 候補一覧.slice(0, 使用件数)
  for (const 使用候補 of 使用候補一覧) {
    // 送信失敗は握りつぶさず、呼び出し元へそのままthrowする
    await 既存の送信関数(使用候補)
  }

  return { 成功: true, 使用件数, 使用候補一覧 }
}
```

対象ファイルと参照ruleは正確な相対パスで列挙する。完了条件にはChangesの実装、対象テスト、必要な型検査・formatを含める。`tdd`は1枚だけ読むため、別設計書を読まないと判定できる条件を置かない。
