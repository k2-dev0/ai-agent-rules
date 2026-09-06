# シナリオ駆動の共通実装フロー

`tdd`と`errand`は、調査後の実装をこの契約へ集約する。呼び出し元のSKILL.mdが入力範囲と停止条件を決め、この文書は調査、シナリオ選択、Red、初回実装、レビューへの引き渡し、Greenの順序を定める。

初回実装後の差分検証、修正主体の判定、再実装、最終レビューは[レビューフロー](REVIEW_FLOW.md)を正本とし、Step 6で読む。この文書では工程の順序と実行する検証を定める。

## 呼び出し元が渡すもの

| 入力 | `tdd` | `errand` |
|---|---|---|
| 要求根拠 | 承認済み設計書と上位モデルが確認した事実 | ユーザー依頼と上位モデルが確認した事実 |
| scope名 | 設計書の機能名 | 呼び出し元が固定するASCII kebab-case名 |
| 実装後の追加処理 | polishと必要ならindex更新 | 呼び出し元が定めた限定検証と完了報告 |

親は[implementerの実装契約](IMPLEMENTER_CONTRACT.md)を読み、初回実装を先に代行せず、その変更境界をbriefと実差分の検証に使う。

## 0. [agent_name]が直接調査する

要求根拠にある識別子、path、番号、固有名詞から、現在の対象、最寄りの同型実装、schema・test・route、直接使える検証commandを[agent_name]が直接確認する。下位モデル、surveyor subagent、外部workerへ調査を委任しない。

調査は要求判断を直接支える最小範囲から始め、根拠の`path:line`、想定変更先、直接関係するtest・検証command、未確認事項を保持する。事実と推測を分け、存在を確認できない実装やtestをあるものとして扱わない。必須事実が不足する場合は[agent_name]が追加調査し、新しい設計判断が必要な場合だけ呼び出し元の停止条件へ戻る。

[設計・実装の判断基準](IMPLEMENTATION_RULES.md)と、そこから案内する該当規約を読み、調査結果へ適用する。

## 1. テストシナリオ候補をまとめて提示する

[agent_name]が要求根拠と確認済み事実から、今回テストする正常系、境界値、異常系、副作用、回帰リスクを候補として選び、各シナリオの前提・操作・期待結果だけをまとめて提示する。実装要件や実装要否を提案・再分類しない。既存テストを正解として盲目的に模倣せず、どの候補を採用・不採用・修正するかはユーザーが決める。選択が確定するまでファイルを変更しない。

候補の末尾では「採用するシナリオ、外すシナリオ、修正点を指定してください。」と尋ねる。全件採用を既定または要求する言い方をしない。ユーザーが明示的に全件採用を選んだ場合だけ、候補全件を`test_scenarios`へ入れる。

ユーザーがシナリオを「不要」とした場合、それはそのテストを作らないという意味だけに限定する。承認されなかった、削除された、または統合されたテストシナリオを、設計書・ユーザー依頼にある実装要件を省略する根拠にしてはならない。実装範囲を変えるには要求根拠自体の明示的な変更が必要である。

次はテストシナリオ変更なので再承認する。

- 期待結果または前提条件を変える
- シナリオを追加、削除、統合する
- 検証対象の責務や公開挙動を変える

選択済みtest_scenariosを忠実に表すためのimport、型、構文、テスト構造の修正は再選択を求めない。新しいテストが必要であることだけを理由に停止しない。要求から公開挙動を一意に決められず、新しい設計判断が必要な場合だけ呼び出し元の停止条件へ戻る。

次のtest除外pathだけの変更では対応test/specの作成・実行とRed / Greenを要求せず、テストシナリオ候補の提示も省略する。

- `schema.prisma`
- basenameが`constants.ts`または`constants.js`のfile
- `constants/`配下のfile

同じ依頼にそれ以外の本体コードの公開挙動変更が含まれる場合、その挙動だけを通常どおりシナリオ、Red、Greenの対象にする。

## 2. [agent_name]がテストを書く

選択済みtest_scenariosと確認済み事実をテスト資産へ変換する。テストの意味を変えるために既存assertionを弱めない。追跡対象はリポジトリのGit規約どおりコミットする。`.gitignore`や`.git/info/exclude`で意図的にignoredなtestはローカルのRedとして使い、`git add -f`でignore規約を迂回しない。追跡済みでもignore対象でもない野良の未追跡testだけを不正として停止する。

`.jsx` / `.tsx` componentとReact hookには、そのためだけの隣接unit testを新設しない。画面挙動は既存のintegration / E2E境界で検証する。

ユーザーが「テストは既に組んである」と明示した場合、シナリオ候補の提示とテスト作成を省略できる。ただし対象となる既存テスト、要求を検出できる理由、実装前のRed確認は省略しない。

## 3. Redを確認し、実装前baselineを記録する

対象テストをプロジェクトの既存test script経由で実行し、実装不足または期待値との差で失敗することを確認する。

- syntax、import、型の失敗はシナリオを変えず[agent_name]が修正する
- 未調査のリポジリ事実が必要ならStep 0の直接調査へ戻す
- 最初からGreenなら、テストが要求を検出できるか確認する
- シナリオの変更が必要ならStep 1へ戻して再承認する

追跡対象のテストをコミットし、ユーザー由来のdirty fileがないことを確認する。実装直前に[polishの実装前baseline](polish/SKILL.md#実装前baseline)をscope名で記録する。worktreeがcleanでなければ実装を開始せず停止する。ignore規則に一致するローカルtestはdirty判定に含めない。

## 4. implementerへ初回実装を委任する

機械検証用JSONやworker artifactを作らず、次を一つの実装briefとして渡す。

- 設計書またはユーザー依頼の全要件
- [agent_name]が確認した事実と`path:line`
- 共通判断基準に沿った調査結果と適用する規約のpath、既存例
- 選択済みtest_scenarios
- Redのcommand、終了status、期待した理由での失敗要約
- 実装後に下位モデルが実行する確認済みtest command
- 想定変更先と、追加production fileを変更してよい条件
- [implementerの実装契約](IMPLEMENTER_CONTRACT.md)のpathと今回の変更禁止範囲

test_scenariosは検証範囲だけを表し、要求根拠の実装範囲を狭めない。

上記briefを専用implementer一体へ渡し、完了を待ってからStep 5へ進む。起動と待機は[implementerの呼び出し方](IMPLEMENTER_LAUNCH.md)に従う。起動できない場合は代替の実装役へ切り替えず、原因を報告する。

## 5. 相談・無変更・中断を処理する

実装subagentがテストの穴、矛盾、曖昧さ、偽陽性・偽陰性を報告した場合は[agent_name]が処理する。

- 追加調査だけで一意に解決できる: [agent_name]が直接確認し、変更前worktreeがcleanな場合だけimplementerを一度再起動する
- 非ブロッキングな改善案: 記録して続行する
- 新しい設計判断が必要: 呼び出し元の設計・要件確認へ戻す

`Outcome: implemented`でも実差分が0なら実装失敗として扱う。説明・分類だけを返した場合も成功に数えない。implementerが一部でも変更した後は、初回実装として再起動せずStep 6のレビューへ進む。subagentが中断・無応答で、cleanな状態からの初回実装再実行も一度失敗した場合だけ上位モデルが初回実装を引き継ぐ。レビュー指摘に対する再実装はこの再起動制限でなく`REVIEW_FLOW.md`に従う。active scope、owner session、lease、handoff、recoverは使わない。

## 6. レビューフローを実行する

[レビューフロー](REVIEW_FLOW.md)を全文読み、実装差分の検証、指摘の大小判定、必要な修正・再実装、採否と修正主体の報告を完了してからStep 7へ進む。

## 7. Green・最終レビュー・修正を完了する

次を上から実行し、無関係なpackageのtestやproject全体のtestを追加しない。

| 条件 | 実行 |
|---|---|
| 選択済みtest_scenariosから作ったtest | 全件 |
| [agent_name]が`direct-regression`として確認した既存test | 全件 |
| TypeScript / JavaScriptを変更 | 所属packageの既存typecheck。なければ`tsc -p <tsconfig> --noEmit` |
| `schema.prisma`を変更 | 所属packageのPrisma `format`、`validate`、`generate` |
| 呼び出し元の完了条件に追加commandがある | そのcommand |

[agent_name]が確認した検証commandは`target-test`、`direct-regression`、`typecheck`、`schema`へ分類し、対象pathと理由を付ける。利用可能なcommandがなければ発明せず、未実行として報告する。下位モデルのtest結果で代用せず、上位モデルがこの実行表を独立に確認する。

検証結果はStep 8でscopeへ帰属させ、[レビューフローの修正ループ](REVIEW_FLOW.md#修正ループ)に従って最終レビューと必要な修正・再検証を完了する。

## 8. 失敗をscopeに帰属させる

[レビューフローの診断のscope帰属](REVIEW_FLOW.md#診断のscope帰属)に従って失敗を分類し、修正対象と報告内容を決める。完了処理は呼び出し元のスキルへ戻す。
