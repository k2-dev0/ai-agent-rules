# 設計書形式

## ファイル

`.[agent_name]/prompt/`へ直接作成・更新する。

| file | 内容 |
|---|---|
| `.prompt.md` | 実装順の`- [ ] branch-<機能名>-prompt.md`だけ |
| `branch-<機能名>-prompt.md` | 単独で実装・完了判定できる1機能 |

機能名はASCII kebab-case。依存先を先に並べ、全項目を未完了で作る。`[x]`へ変えるのは引数なしtddだけ。

1枚を原則1 branch・squash後1 commitにする。APIとschema、migrationとschema変更、helper・定数と利用箇所、testと対象実装は同じ設計書。UIはcomponent単位。

## 必須section

````markdown
# <機能名>

## Summary
<目的・利用者に見える結果を1〜2行>

## Changes
```typescript
// <対象ファイル>
<構造化疑似コード>
```

## 対象ファイル
- @<相対パス>

## 参照ルール
- @.[agent_name]/rules/<関連rule>

## 設計根拠
- <明示要件・禁止制約・受入済みtrade-off・既存制約／変更可能な設計選択>
- <新設要素のconsumer、同責務の既存例path:line・export、適用規約、代替案の不足>

## 完了条件
- <実装・検証・構造・配置・命名をこの1枚で判定できる条件>
````

## Changes

実装者が挙動を再設計せずコードへ変換できる密度で書く。

| 書き方 | 対象 | 例 |
|---|---|---|
| 実名 | 既存symbol・schema field・file path | `customer_no`、`src/service.ts` |
| 英語 | 予約語・演算子・構文・組み込み型/object、標準・外部library・framework API、method・property | `export`、`async`、`if`、`Promise`、`.map()` |
| 日本語 | 新設する業務関数・引数・変数・型・結果field・error・処理 | `使用件数`、`保有件数超過` |

上の行を優先する。新設識別子の実装時の英語名は固定しない。配列は`[]`、objectは`{}`を宣言・参照の両方へ付ける（`候補一覧[].length`、`候補一覧[].slice(...)`、`利用結果{}`）。

### 構造化疑似コードの例

以下はSMS送信処理の抜粋（import・schema定義は省略）。既存の`defineHandler`・`prisma.user`・`sendSMS`・field名は維持する。実行用コードではなく記法の例。

```typescript
// front/transactions/v2/t67_01__hdb_karaden_soushin.ts
export const t67_01__hdb_karaden_soushin = defineHandler(
  XMLメール通知schema,
  async 入力{} => {
    try {
      let 送信先電話番号 = 入力{}.data.to;
      if (/^A/.test(送信先電話番号)) {
        const 顧客{} = await prisma.user.findUnique({
          where: { customer_no: 送信先電話番号 },
          select: { contact_phone_number: true },
        });
        if (顧客{} === null) throw new Error("顧客不存在");
        送信先電話番号 = 顧客{}.contact_phone_number;
      }
      if (!/^0[789]0\d{8}$/.test(送信先電話番号)) {
        throw new Error("携帯電話番号不正");
      }
      await sendSMS({ tel: 送信先電話番号, txt: 入力{}.data.smsBody });
    } catch {
      const 通知結果{} = await sendMail({
        from: SMTP_MAIL_FROM,
        to: 入力{}.data.notificationEmail,
        subject: `[SMS送信失敗]${入力{}.data.smsSubject}`,
        text: "SMS送信処理に失敗しました",
      });
      if (通知結果{} === null) {
        throw new InternalServerError({ message: "失敗通知を送信できませんでした" });
      }
    }
  },
);
```

### 省略しない情報

| 対象 | 省略しない情報 |
|---|---|
| 関数 | export/local、同期/async、引数、guardの評価順、導出値と計算式、正常・errorの区別と返却field |
| validation | nullを含む入力形状、条件付き必須、形式条件、client検証とserverの最新dataによる再検証 |
| DB/API | 認証主体、`where`の全条件と日付境界、sort・tie-break、dataの権威、再取得・再検証・選択、公開field |
| 副作用 | error処理とDB書き込み、メール、外部APIの順序・field mapping・await・失敗時処理 |
| 共通要素 | 定数・配列の形、consumer、他の値から導出する関係 |

分岐・loopは構文で書く。「検証／取得／errorを返す」だけで済ませず条件を示す。同一処理はloopへまとめ、共通処理と対象固有の差を残す。

圧縮してよいのは重複説明と同一の外枠だけ。guard順・条件式・等号・計算式・sort・tie-break・返却field・状態遷移・副作用・dataの権威を文章一行へ畳まない。Summary・完了条件でChangesを言い直さない。

対象file・参照ruleは正確な相対pathとし、[判断基準](../IMPLEMENTATION_RULES.md)を適用する。
