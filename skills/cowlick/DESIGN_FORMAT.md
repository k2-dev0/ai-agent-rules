# cowlick設計書形式

`draft` modeはこの文書を全文読み、次の形式を崩さない。

## ファイル構成

`draft-prompt/`には次だけを置く。

| ファイル | 契約 |
|---|---|
| `.prompt.md` | 実装順の`- [ ] branch-<機能名>-prompt.md`だけを並べるindex |
| `branch-<機能名>-prompt.md` | 1機能の自己完結した設計書 |

機能名はbranch名に使えるASCII kebab-caseとする。全項目を未完了で作り、`[x]`への変更はconductorだけが行う。依存される機能を先に並べる。

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

Changesでは予約語、構文、library API名を英語のまま使い、関数・引数・処理内容を日本語で書く。分岐とloopは文章へ畳まず`if`、`switch`、`for`等の構造を示す。error処理とDB書き込み、メール、外部APIなどの副作用を一つずつ書き、行数削減のために省略しない。実装時の英語識別子は固定しない。

対象ファイルと参照ruleは正確な相対パスで列挙する。完了条件にはChangesの実装、対象テスト、必要な型検査・formatを含める。conductorは1枚だけ読むため、別設計書を読まないと判定できる条件を置かない。
