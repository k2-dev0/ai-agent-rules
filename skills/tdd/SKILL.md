---
name: tdd
description: ユーザーが `$tdd from-prompt` または `$tdd <承認済み設計書path>` を明示し、設計書1枚をDeepSeek調査・初回実装、上位モデルのテスト設計・レビュー・修正、polishまで実行するときに使う。from-promptだけ実装順indexを更新する。
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent, Skill(polish)
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/require-test.sh
---

## 目的

[agent_name]を設計・テスト・レビュー・修正の責任者、DeepSeekを調査と制限された初回実装の担当として、承認済み設計書1枚を`survey → scenario → red → delegated-green → review-green → polish`で完了する。

## 入力mode

先頭引数を次のどちらかに限定する。引数なし、追加引数、存在しないpathでは変更せず`invalid_scope`を返す。

- `from-prompt`: `@.[agent_name]/prompt/.prompt.md`の先頭の`- [ ] branch-<機能名>-prompt.md`だけを選ぶ。他の設計書を読まず、完了後だけ同じ行を`[x]`へ変更する
- `<承認済み設計書path>`: 指定された既存Markdown 1枚だけを使う。indexを探索・変更しない

`from-prompt`でindexがない、空、参照先がない場合は変更せず停止する。未完了項目がなければ全設計書が完了済みと報告する。どちらのmodeも設計書1枚を1 branch・1 PRの単位として扱い、次の設計書へ自動で進まない。

## 権限境界

| 対象 | [agent_name] | DeepSeek |
|---|---|---|
| テストシナリオ設計 | 可 | 禁止。既存テストの事実報告だけ可 |
| テスト資産の変更 | 承認済みシナリオ内だけ可 | 禁止 |
| 設計資産の変更 | cowlickの承認後だけ可 | 禁止 |
| 許可された本体コードと`schema.prisma`の初回実装 | DeepSeekの2回連続応答失敗または認証失敗後だけ可 | 可 |
| DeepSeek候補反映後の本体コード修正 | 可 | 禁止 |
| テスト実行・レビュー・Git | 可 | 禁止 |

テスト資産には、test/spec、fixture、factory、mock、stub、fake、snapshot、golden file、テスト設定、CI上のテスト実行設定を含める。

`schema.prisma`自体はテスト対象外とし、対応するtest/specとRed/Greenを要求しない。変更対象が`schema.prisma`だけならシナリオ承認とStep 3・4を省略し、Step 5以降で実装する。Prisma CLIが導入済みなら既存scriptまたは`node_modules/.bin/prisma`からformat、validate、generateを実行して検証する。同じ設計に本体コードの公開挙動変更が含まれる場合、その挙動は通常どおりシナリオ、Red、Greenの対象とする。

## 通常ゲート

通常のユーザー承認は、実装前の**シナリオ一括承認**だけとする。各シナリオについて前提、操作、期待結果を提示する。承認後、具体的なテストコードは[agent_name]が自動で作る。

次はシナリオ変更なので再承認する。

- 期待結果または前提条件を変える
- シナリオを追加、削除、統合する
- 検証対象の責務や公開挙動を変える

承認済みシナリオを忠実に表すためのimport、型、構文、テスト構造の修正は再承認しない。

## 実行フロー

### 1. 対象と変更範囲を確定する

選んだ設計書の対象ファイルを、テスト資産、DeepSeekへ渡す本体コードと`schema.prisma`、その他の保護対象へ分類する。test/spec、fixture、factory、mock、stub、fake、snapshot、Markdown、設定、依存関係、migration、Git管理ファイルはDeepSeekへ渡さない。委任対象pathに未コミット変更があればユーザー変更との衝突として停止する。

### 2. 調査を委任してシナリオを承認する

関連するrules、最寄りの同型実装、既存テストの正確なpathと実行方式、fixture・DB初期化、検証commandをDeepSeekの`survey`へ委任する。各commandを`target-test`、`direct-regression`、`typecheck`、`schema`へ分類し、対象pathと理由を返させる。DeepSeekにはテストシナリオ、期待値、assertion、fixture構成、テストコードを提案または変更させない。

[agent_name]はsurvey前に関連コードをGrep / Glob / git logで探索しない。report受領後も直接読むのは重要な`file:line`の確認だけとし、不足があれば調査項目を絞った新しいsurveyへ戻す。共通契約の失敗条件を満たすまで自力の横断探索へ切り替えない。

設計書とsurveyが集めた事実を根拠に、[agent_name]が正常系、境界値、異常系、副作用、回帰リスクとテスト構造を設計して提示する。既存テストを正解として模倣せず、承認されるまでファイルを変更しない。`schema.prisma`だけの変更ではsurvey結果から既存schema patternと検証commandを確定するが、シナリオ承認は要求しない。

### 3. [agent_name]がテストを書く

承認済みシナリオだけをテストへ変換する。追跡対象のファイルは1ファイルずつ即コミットする。無視されたテスト資産は `git add -f` / `git add --force` を使わず、作業ツリーに残して検証と後続工程を継続する。テストの意味を変えるために既存assertionを弱めてはならない。

### 4. Redを確認する

対象テストをプロジェクトのtest script経由で実行し、実装不足または期待値との差で失敗することを確認する。

- syntax/import/typeの失敗は、シナリオを変えず[agent_name]が修正する
- 最初からGreenなら、テストが要求を検出できるか検証する
- テスト自体またはシナリオの変更が必要なら再承認へ戻る

### 5. DeepSeekへ初回実装を委任する

`implement` modeへ設計書、テスト結果の要約、変更可能な本体コードまたは`schema.prisma`の相対パスだけを渡す。DeepSeekにはシェル、Git、外部通信、テスト・設計・設定の編集を許可しない。[agent_name]はDeepSeekの最初の応答前にstub、雛形、部分実装を作らず、共通契約の条件を満たした場合だけ初回実装を引き継ぐ。

### 6. 相談を処理する

DeepSeekがテストの穴、矛盾、曖昧さ、偽陽性・偽陰性を報告したら[agent_name]が根拠を検証する。

- 既存の承認内容から一意に解決できる: [agent_name]が回答し、新しいtask-idで再委任する
- 非ブロッキングな改善案: 記録して実装を継続する
- 新しい設計判断またはテストシナリオが必要: ユーザー承認へ戻る

DeepSeekには発言権だけを認め、テスト・設計の編集権と決定権は与えない。

### 7. 候補パッチを検証して反映する

`result.json`、`opencode.jsonl`、`candidate.patch`を読む。自己申告ではなく実際のパッチを正とし、次を確認する。

- 変更が許可パス内だけである
- テスト資産、設計、設定、Gitを変更していない
- テスト環境検出、値のハードコード、assertion攻略がない
- 承認済み設計とシナリオに一致する

候補が返った後の採否は上位モデルのレビュー責務である。安全に修正できる問題なら、候補を土台に[agent_name]が直接直す。許可外変更や設計逸脱でパッチ全体を拒否しても、DeepSeekへレビュー・修正を戻さず、[agent_name]が承認済み設計の範囲で実装を完成させる。問題がなければ追跡対象を1ファイルずつ反映して即コミットする。無視されたファイルは作業ツリー上で検証し、強制stageはしない。

### 8. [agent_name]がGreen・レビュー・修正を完了する

次を上から実行する。無関係なpackageのtestやproject全体のtestは追加しない。

| 条件 | 実行 |
|---|---|
| 承認済みシナリオから作ったtest | 全件 |
| surveyが`direct-regression`として返した既存test | 全件 |
| TypeScript / JavaScriptを変更 | 所属packageの既存typecheck。なければ`tsc -p <tsconfig> --noEmit` |
| `schema.prisma`を変更 | 所属packageのPrisma `format`、`validate`、`generate` |
| 設計書の完了条件に追加commandがある | そのcommand |

利用可能なcommandがなければ発明せず、未実行として報告する。候補反映後は[agent_name]が差分をレビューし、承認済み設計へ合わせる本体コード修正を直接行う。通常の修正をDeepSeekへ再委任しない。テストまたは設計を変える必要が出た場合だけ承認フローへ戻る。

### 9. polishと完了処理を行う

設計書の完了条件、Step 8の検証、レビュー、追跡対象のコミットを確認してから`polish`を必ず呼ぶ。機能名と、この実行で変更してコミットした追跡済み本体コードの相対path一覧を渡す。`polish`が変更した場合はStep 8とレビューをやり直し、変更をコミットして品質ゲートを再実行する。

`from-prompt`では、polishが現在のHEADへquality receiptを記録した後だけ次を単独実行する。失敗時はindexを直接編集しない。

```bash
bash [skills_root]/tdd/mark-prompt-done.sh <機能名>
```

設計書path modeではquality receiptと`mark-prompt-done.sh`を使わず、indexへ触れない。

## 例外停止

次の場合は正常な自動区間を停止する。

- 共通委任契約が停止対象とする予算、ZDR、依存commandの問題がある
- DeepSeekが許可外パスを変更した
- ユーザーの未コミット変更と対象パスが衝突する
- 2回の応答失敗後も上位モデルの実装経路を利用できない
- DB、依存関係、公開APIなど承認範囲外の変更が必要になる

## 完了条件

- 承認済みシナリオがすべてGreen
- Step 8とpolishの検証が成功
- [agent_name]が差分をレビュー済み
- 追跡対象の変更が1ファイルずつコミット済み
- 無視された対象変更は作業ツリー上で検証済みで、未コミットである理由を完了報告に含めた
- polishの品質ゲートが完了した
- `from-prompt`では同じ機能名・現在のHEADのquality receiptを検証してindexを更新した

対象設計書、承認シナリオ、Red、Green、DeepSeekの相談・採否理由・survey / implement / nestingのtask-id、polish結果、コミットを完了報告へ含める。`from-prompt`ではindexの残件数も含める。
