# シナリオ駆動の共通実装フロー

`tdd`と`errand`は、調査後の実装をこの契約へ集約する。呼び出し元のSKILL.mdが入力範囲と停止条件を決め、この文書をnative調査・シナリオ・テスト・初回実装・Greenの正本とする。

## 呼び出し元が渡すもの

| 入力 | `tdd` | `errand` |
|---|---|---|
| 要求根拠 | 承認済み設計書とnative survey結果 | ユーザー依頼とnative survey結果 |
| implementerへの入力 | 全要件、確認済み事実、test_scenarios、Red、想定変更先 | 全要件、確認済み事実、test_scenarios、Red、想定変更先 |
| scope名 | 設計書の機能名 | 呼び出し元が固定するASCII kebab-case名 |
| 実装後の追加処理 | polishと必要ならindex更新 | 呼び出し元が定めた限定検証と完了報告 |

想定変更先は調査とレビューの起点であり、書き込み認可リストではない。要件内で別のproduction fileが必要だと判明した場合、implementerは変更してよい。親が共有worktreeの実差分を全件レビューし、test/spec、fixture、設定、migration、依存関係、lockfile、agent設定、設計資産、Git管理ファイルへの変更を採用しない。

## 0. native survey subagentへ調査を委任する

最初に次を実行し、Claude CodeとCodexの専用`surveyor`・`implementer`定義を検査する。

```bash
bash [skills_root]/tdd/preflight-implementer.sh [agent_name]
```

必要な調査をsource group単位へ分け、独立した調査は最大3体を並行起動する。一体へリポジトリ全体を任せず、現在の対象、最寄りの同型実装、schema・test・routeなど、同じfile群を読む事実だけを一つのtaskへまとめる。Claude Codeではproject agent `surveyor`を、Codexではtask名`surveyor`、`fork_turns: "none"`、専用agent定義のread-only sandboxを使う。

surveyorには次を自然文で渡す。

- 要求根拠と今回確認する一つの判断
- 既知の識別子、path、番号、固有名詞
- 読むsource groupと除外範囲
- 返答に必要な、確認済み事実、根拠の`path:line`、想定変更先、直接関係するtest・検証command、未確認事項

返答をMarkdown parser、claim ID、Evidence件数、artifact blobで検証しない。親が内容と`path:line`を読み、要求判断を直接支えるか採否する。必要な事実が一つだけ欠けた場合は、新しいtaskを作らず同じsurveyorへ一度だけ限定follow-upする。別source groupが必要なら別taskにする。native agentの完了通知を待ち、短周期pollや固定時間での打ち切りを行わない。

surveyorにはシナリオ、期待値、assertion、fixture構成、テストコードを提案または変更させない。調査結果に矛盾がある、高リスク判断を独立確認する、未コミット状態やruntimeが対象である場合は、親が理由を明記して限定確認する。

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
- 未調査のリポジトリ事実が必要ならStep 0の限定follow-upへ戻す
- 最初からGreenなら、テストが要求を検出できるか確認する
- シナリオの変更が必要ならStep 1へ戻して再承認する

追跡対象のテストをコミットし、ユーザー由来のdirty fileがないことを確認してから、native implementer起動直前に次を1回実行する。

```bash
bash [skills_root]/polish/capture-scope.sh <scope名> --auto
```

これは現在HEADをpolish用baselineとして記録するだけで、subagentの書き込みを認可・拒否しない。worktreeがcleanでなければ共有worktreeへwriterを起動せず停止する。ignore規則に一致するローカルtestはdirty判定に含めない。

## 4. native implementerへ初回実装を委任する

機械検証用JSONやworker artifactを作らず、次を一つの実装briefとして渡す。

- 設計書またはユーザー依頼の全要件
- surveyorが確認した事実と`path:line`
- 選択済みtest_scenarios
- Redのcommand、終了status、期待した理由での失敗要約
- 想定変更先と、追加production fileを変更してよい条件
- 変更禁止カテゴリ

test_scenariosは検証範囲だけを表し、要求根拠の実装範囲を狭めない。

`implementer` subagentを一体だけforegroundで起動して完了まで待つ。Claude Codeではproject agent `implementer`を使う。Codexではtask名`implementer`、`fork_turns: "none"`、`model: "gpt-5.6-luna"`、`reasoning_effort: "max"`を明示してfresh contextで起動する。child agent IDが空、wait先が空、または専用agent定義を使えない場合はwriterを起動しない。短周期poll、固定時間での打ち切り、別implementerの並列起動は禁止する。

## 5. 相談・無変更・中断を処理する

実装subagentがテストの穴、矛盾、曖昧さ、偽陽性・偽陰性を報告した場合は[agent_name]が処理する。

- 追加調査だけで一意に解決できる: 同じsurveyorへ一度だけ限定follow-upし、変更前worktreeがcleanな場合だけ一度再起動する
- 非ブロッキングな改善案: 記録して続行する
- 新しい設計判断が必要: 呼び出し元の設計・要件確認へ戻す

`Outcome: implemented`でも実差分が0なら実装失敗として扱う。説明・分類だけを返した場合も成功に数えない。implementerが一部でも変更した後は再委任しない。subagentが中断・無応答で、cleanな状態からの再実行も一度失敗した場合だけ親が初回実装を引き継ぐ。active scope、owner session、lease、handoff、recoverは使わない。

## 6. 実装差分を検証する

subagentの自己申告や想定変更先ではなく、共有worktreeの実際の差分を正として全件確認する。

- 変更が要求根拠の範囲内であり、追加pathが必要だった因果を説明できる
- test/spec、fixture、設定、migration、依存関係、lockfile、agent設定、設計、Git管理ファイルを変更していない
- テスト環境検出、値のハードコード、assertion攻略がない
- 全要件に一致し、test_scenariosの採否を実装省略へ流用していない

正しい処理であることに加え、半年後に負債にならないかを必ずレビューする。

- 独立した業務責務を持たないhelperや薄いwrapperで関数ジャンプを増やしていない
- 現在の要件に不要な共通化、設定可能性、将来用拡張点を作らずYAGNIに従っている
- 制御フローとデータ変換を上から自然に追える
- `filter().map()`で意図が明確になる処理を短さだけで`reduce()`へ畳み込んでいない
- 多少冗長でも局所的に理解できる名前と構造を選んでいる

採否は上位モデルのレビュー責務とする。安全に修正できる問題は差分を土台に[agent_name]が直接直す。通常の修正をsurveyorまたはimplementerへ再委任しない。

Green、formatter、lint、polish、本体コードのcommitより先に、次の3項目だけを簡潔に報告する。

- 採用: 実装者が変更した内容と採用理由
- 問題: 問題箇所、影響、採用・修正・拒否の判断
- 上位修正: 上位モデルが変更した内容と理由

問題や上位修正がなければ「なし」と根拠を一文で示す。コードの再掲、作業手順、内部推論は報告しない。追跡対象の本体変更は、この報告後にリポジトリのGit規約どおりコミットする。

## 7. Green・レビュー・修正を完了する

次を上から実行し、無関係なpackageのtestやproject全体のtestを追加しない。

| 条件 | 実行 |
|---|---|
| 選択済みtest_scenariosから作ったtest | 全件 |
| surveyorが`direct-regression`として確認した既存test | 全件 |
| TypeScript / JavaScriptを変更 | 所属packageの既存typecheck。なければ`tsc -p <tsconfig> --noEmit` |
| `schema.prisma`を変更 | 所属packageのPrisma `format`、`validate`、`generate` |
| 呼び出し元の完了条件に追加commandがある | そのcommand |

surveyorが確認する検証commandは`target-test`、`direct-regression`、`typecheck`、`schema`へ分類し、対象pathと理由を付ける。利用可能なcommandがなければ発明せず、未実行として報告する。初回実装後は[agent_name]が差分をレビューし、全要件へ合わせる本体コード修正を直接行う。

## 8. 失敗をscopeに帰属させる

test、typecheck、lint、Prisma検証の終了codeだけで今回の成否を決めず、各diagnosticを次へ分類する。

- `scope-related`: 選択済みシナリオの対象test、実変更path自体、または変更した公開型・契約が原因と確認できるcallerの失敗
- `unrelated`: 実変更pathと因果関係がない既存失敗、今回作成・変更していないignored / untracked test、checkout前の残留testの失敗
- `uncertain`: 診断情報だけで因果関係を確定できない失敗

`scope-related`だけを修正・再検証の対象にする。承認範囲内の修正を尽くしても残る場合は`scope fail`として報告へ進む。`unrelated`は対象外fileを変更せず、command、diagnostic、根拠を報告してworkflowを続ける。`uncertain`は推測で緑または赤に倒さない。どの分類が残っていても完了マークを自動判定せず、判断はユーザーに委ねる。
