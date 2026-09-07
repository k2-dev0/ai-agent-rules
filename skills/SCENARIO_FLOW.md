# シナリオ駆動の共通実装フロー

`tdd`と`errand`は、調査後の実装をこの契約へ集約する。入力・停止条件・実装後の処理は呼び出し元に従う。

| 入力 | tdd | errand |
|---|---|---|
| 要求根拠 | 承認済み設計書と確認済み事実 | ユーザー依頼と確認済み事実 |
| scope名 | 設計書の機能名 | ASCII kebab-case名 |
| 実装後 | polish・必要ならindex更新 | 限定検証・完了報告 |

[実装契約](IMPLEMENTER_CONTRACT.md)を読む。初回実装を先に代行せず、契約をbriefとレビューへ適用する。

## 0. [agent_name]が直接調査する

要求の識別子・path・番号・固有名詞から対象、同型実装、schema・test・route、検証commandを確認する。サブエージェントへ調査を委任しない。

`path:line`、想定変更先、関連test・command、未確認事項を保持する。事実と推測を分け、必須事実が不足する場合は[agent_name]が追加調査する。新しい設計判断が必要なら呼び出し元へ戻す。[判断基準](IMPLEMENTATION_RULES.md)と該当規約を適用する。

## 1. テストシナリオ候補をまとめて提示する

要求と確認済み事実から、正常・境界値・異常・副作用・回帰の候補を「前提・操作・期待結果」で提示する。どの候補を採用・不採用・修正するかはユーザーが決める。選択が確定するまでファイルを変更しない。

「採用するシナリオ、外すシナリオ、修正点を指定してください。」と尋ねる。全件採用を既定または要求する言い方をしない。選択結果を`test_scenarios`とする。

シナリオの不採用・削除・統合を、実装要件を省略する根拠にしてはならない。実装範囲の変更には要求根拠の明示的な変更が必要。

| 変更 | 再選択 |
|---|---|
| シナリオ追加・削除・統合、前提・期待結果・対象責務・公開挙動の変更 | 必要 |
| 選択済みシナリオを保つimport・型・構文・テスト構造の修正 | 不要 |

新しいテストが必要であることだけを理由に停止しない。公開挙動を一意に決められない場合は設計確認へ戻す。

次のtest除外pathだけの変更では対応test/specの作成・実行とRed / Greenを要求せず、候補提示も省略する。

- `schema.prisma`
- basenameが`constants.ts`または`constants.js`
- `constants/`配下

その他の本体コードの公開挙動も変える場合は、その挙動だけを通常どおりシナリオ、Red、Greenの対象にする。

## 2. テストを書く

選択済みシナリオを実装し、既存assertionを弱めない。追跡対象はGit規約どおりコミットする。ignore規則に一致するtestはローカルで使い、`git add -f`しない。追跡・ignoreのどちらにも該当しない未追跡testは停止対象。

`.jsx` / `.tsx` component・React hook専用の隣接unit testは新設せず、既存integration / E2E境界で検証する。

ユーザーがテスト作成済みと明示した場合は、候補提示・作成を省略できる。対象test、要求を検出できること、実装前のRedは確認する。

## 3. Redと実装前baseline

既存test scriptで対象testを実行し、実装不足・期待値との差による失敗を確認する。

| 結果 | 対応 |
|---|---|
| syntax・import・型の失敗 | シナリオを変えず修正 |
| 未確認の事実が必要 | Step 0へ戻る |
| 最初からGreen | 要求を検出できるtestか確認 |
| シナリオ変更が必要 | Step 1へ戻る |

追跡対象testをコミットし、worktreeがcleanであることを確認する。ユーザー由来のdirty fileが残れば実装を停止する。ignored testはdirtyに含めない。実装直前に[polishの実装前baseline](polish/SKILL.md#実装前baseline)をscope名で記録する。

## 4. 初回実装を委任する

次のbriefを専用implementer一体へ渡し、[起動手順](IMPLEMENTER_LAUNCH.md)で完了を待つ。起動不能は報告し、代替roleへ切り替えない。

- 全実装要件、確認済み事実と`path:line`
- 判断基準・適用規約のpath・既存例
- `test_scenarios`、Redのcommand・終了status・失敗内容
- 実装後に実行する確認済みtest command
- 想定変更先、追加production fileの変更条件、実装契約のpath・変更禁止範囲

検証シナリオで実装範囲を狭めない。機械検証用JSON・worker artifactは作らない。

## 5. 相談・無変更・中断

| 結果 | 対応 |
|---|---|
| 追加調査で一意に解決できる | 直接調査し、変更前worktreeがcleanの場合だけ一度再起動 |
| 非ブロッキングな改善案 | 記録して続行 |
| 新しい設計判断 | 呼び出し元へ戻る |
| `Outcome: implemented`でも実差分0、説明・分類のみ | 実装失敗 |
| 一部でも変更済み | 初回実装を再起動せずStep 6へ |

中断・無応答で、cleanな状態からの初回実装再実行も一度失敗した場合だけ親が実装を引き継ぐ。レビュー後の再実装は次のレビューフローに従う。

## 6. レビュー

[レビューフロー](REVIEW_FLOW.md)を全文読み、全差分の検証、大小判定、修正・再実装、採否・修正主体の報告を完了する。

## 7. Green・最終レビュー

親が次を順に実行する。下位モデルの結果で代用せず、無関係なpackageのtestやproject全体のtestを追加しない。

| 条件 | 実行 |
|---|---|
| 選択済みシナリオのtest | 全件 |
| 直接の回帰検証と確認した既存test | 全件 |
| TypeScript / JavaScript変更 | 所属packageのtypecheck。なければ`tsc -p <tsconfig> --noEmit` |
| `schema.prisma`変更 | 所属packageのPrisma `format`、`validate`、`generate` |
| 呼び出し元の追加完了条件 | 指定command |

commandは`target-test`、`direct-regression`、`typecheck`、`schema`に分類し、対象pathと対応を示す。commandがなければ発明せず未実行と報告する。[修正ループ](REVIEW_FLOW.md#修正ループ)で最終レビュー・修正・再検証を完了する。

## 8. 失敗の分類

[診断のscope帰属](REVIEW_FLOW.md#診断のscope帰属)に従って分類し、完了処理は呼び出し元へ戻す。
