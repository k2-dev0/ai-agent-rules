# 設計書形式

## ファイル

`.[agent_name]/prompt/`へ直接作成・更新する。

| file | 内容 |
|---|---|
| `.prompt.md` | 実装順の`- [ ] branch-<機能名>-prompt.md`だけ |
| `branch-<機能名>-prompt.md` | 単独で実装・完了判定できる1機能 |

機能名はASCII kebab-case。依存先を先に並べ、全項目を未完了で作る。`[x]`へ変えるのは`tdd --from-doc`だけ。

1枚を原則1 branch・squash後1 commitにする。APIとschema、migrationとschema変更、helper・定数と利用箇所、testと対象実装は同じ設計書。UIはcomponent単位。

## 必須section

要件・設計判断・図表の項目とその参照には、内容が分かる具体名を使う。`R1`・`D5`のような略号＋連番は使わない。

````markdown
# <機能名>

## Summary
<目的・利用者に見える結果を1〜2行>

## Changes
<フローチャート・ステートダイアグラム・シーケンスダイアグラムで処理を示す>

<図中では長文になる補足・パラメータの種類や型など、図示に適さない詳細だけを必要に応じて契約表にする>

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

実装方法ではなく、外部から確認できる振る舞いと実装が守る契約を書く。処理は可能な限り図で示し、複雑さの中心に応じて次から主要表現を1つ選ぶ。

| 複雑さの中心 | 表現 |
|---|---|
| 処理順・分岐・条件の組み合わせ | Mermaid `flowchart` |
| lifecycle・再試行・取消 | Mermaid `stateDiagram-v2` |
| component・外部service間の通信順 | Mermaid `sequenceDiagram` |

主要表現だけでは異なる種類の振る舞いを確定できない場合だけ2つ目を加える。file一覧・class構成は処理図にしない。

各図の直前に、対象の処理名と対応箇所（相対file path、既存の関数・method名やAPI endpoint）を1行で明記する。

### 契約表

図中では長文になり読みにくい補足、パラメータの種類・型・制約など、図示に適さない詳細だけを書く。Markdownの決定表も長い条件の補足に限る。処理順・分岐・状態遷移・通信順は図に残す。非該当行、既存規約から一意に決まる実装、図と同じ内容は書かない。

| 項目 | 残す情報 |
|---|---|
| 入力・出力 | nullを含む入力形状、条件付き必須、公開する正常結果・field |
| 判定 | guardの優先順位、条件式、境界・等号、計算式、sort・tie-break |
| 不変条件 | 認証・整合性・重複・競合・data lossを防ぐ条件 |
| error | 発生条件、呼出元から区別する結果、既存dataの扱い |
| 副作用 | DB書き込み・メール・外部APIの完了保証、部分失敗時のdataの扱い |
| dataの権威 | 判定に使う最新data、再取得・再検証・選択条件 |

既存symbol・schema field・file path・外部契約名は実名で書く。新設するlocal変数・関数内構造・実装時の英語名は固定しない。

### 例

SMS送信処理（`src/sms.ts`、`sendSMS`・`sendMail`）

```mermaid
flowchart TD
  A[送信先を受け取る] --> B{toがA始まりか}
  B -->|yes| C[customer_noでprisma.userの電話番号を取得]
  C -->|存在しない| X[顧客不存在]
  B -->|no| D[入力値を使用]
  C -->|存在する| E{携帯電話番号として有効か}
  D --> E
  E -->|no| Y[電話番号不正]
  E -->|yes| F[sendSMSで送信]
  F -->|失敗| G[sendMailで失敗通知]
  G -->|失敗| Z[InternalServerError]
  G -->|成功| I[SMS送信失敗]
  F -->|成功| H[完了]
```

| 項目 | 契約 |
|---|---|
| 入力 | `to`: string（顧客番号または電話番号） |
| 判定 | 携帯電話番号は`^0[789]0\d{8}$`に一致必須 |

### 書かない情報

- `const`・`let`・`await`・object組立てなどの実装構文
- local変数名、関数内部のblock構造、新設symbolの実装時の英語名
- 既存patternと参照ruleから一意に決まるAPI・frameworkの呼び出し方
- 対象コードとtestから導出できる実装順
- Summary・完了条件・図・契約表の間の言い換え

図の簡略化のために、状態・event・guard・境界値・error・副作用・dataの権威を省略しない。対象file・参照ruleは正確な相対pathとする。
