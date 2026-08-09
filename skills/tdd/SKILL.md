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

| mode | 対象 | 完了時のindex更新 |
|---|---|---|
| `from-prompt` | `@.[agent_name]/prompt/.prompt.md`の先頭の`- [ ] branch-<機能名>-prompt.md`だけ。他の設計書は読まない | 同じ行だけを`[x]`へ変更する |
| `<承認済み設計書path>` | 指定された既存Markdown 1枚だけ | indexを探索・変更しない |

`from-prompt`でindexがない、空、参照先がない場合は変更せず停止する。未完了項目がなければ全設計書が完了済みと報告する。どちらのmodeも設計書1枚を1 branch・1 PRの単位として扱い、次の設計書へ自動で進まない。

## 権限境界

| 対象 | [agent_name] | DeepSeek |
|---|---|---|
| テストシナリオ設計 | 可 | 禁止。既存テストの事実報告だけ可 |
| テスト資産の変更 | 承認済みシナリオ内だけ可 | 禁止 |
| 設計資産の変更 | cowlickの承認後だけ可 | 禁止 |
| 本体コード、schema、rules、既存テスト基盤、同型実装の探索 | fallback条件成立後、または具体的疑義の限定検証だけ可 | 可 |
| 許可された本体コードと`schema.prisma`の初回実装 | DeepSeekの2回連続応答失敗または認証失敗後だけ可 | 可 |
| DeepSeek候補反映後の本体コード修正 | 可 | 禁止 |
| テスト実行・レビュー・Git | 可 | 禁止 |

テスト資産には、test/spec、fixture、factory、mock、stub、fake、snapshot、golden file、テスト設定、CI上のテスト実行設定を含める。

### 探索禁止区間

Step 1で設計書を選んでからStep 5のDeepSeek初回実装候補を受領するまで、[agent_name]が直接読めるリポジトリ内ファイルを次に限定する。

- 対象設計書1枚と`from-prompt`で必要なindex 1枚
- 今回変更するテスト資産そのもの
- DeepSeekが返した`result.json`、`report.md`、`candidate.patch`、`opencode.jsonl`
- [agent_name]自身がこの実行で作成したファイル

この区間では、本体コード、`schema.prisma`、rules、package・test設定、既存helper・fixture・seed、同型実装をRead / Grep / Glob / Explorer / `rg` / `grep` / `sed` / `cat` / `git show`などで通常調査しない。DeepSeekの`file:line`はreportの監査根拠であって、[agent_name]が全件を再読する許可ではない。import、型、列名、fixture形式、実行commandの情報が1点でも足りなければ、推測や直接確認をせず、未解決項目だけを新しい`survey`へ戻す。テストシナリオの設計と採否判断は[agent_name]の責務であり、この探索禁止に含めない。

テスト実行のdiagnosticと、[agent_name]が変更するテスト資産の読み直しは探索に含めない。diagnosticだけでテストコードを一意に直せずリポジトリ側の事実確認が必要なら、同じく`survey`へ戻す。

[agent_name]が直接調査へ切り替えてよいのは次だけとする。

1. 共通契約の応答失敗・認証失敗によるfallback条件が成立した
2. [agent_name]またはユーザーが、reportの特定claimへ具体的な疑義を示した

疑義には、report内の矛盾、根拠行の欠落、設計書との不一致、test diagnosticとclaimの衝突を含む。単なる情報不足や「念のため」は疑義に含めず、限定surveyへ戻す。疑義を検証するときは、疑わしいclaim、疑義の根拠、読むpathまたは範囲を先にユーザーへ明示し、その確認に必要な最小範囲だけを直接読む。通常のsurveyを上位モデルが全件再実施してはならない。

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

機能名と、今回変更する追跡済み本体コードおよび`schema.prisma`の相対pathを確定し、変更前に次を1回実行する。新規pathはまだ存在しなくてよい。設計書path modeの機能名は`branch-<機能名>-prompt.md`から得る。

```bash
bash [skills_root]/polish/capture-scope.sh <機能名> -- <相対path>...
```

これは後で`polish`が使う基準commitと対象pathを固定するだけで、品質検査や完了receiptの記録は行わない。開始前から対象pathがdirtyなら停止する。後から対象pathを推測追加しない。

### 2. 調査を委任してシナリオを承認する

関連するrules、最寄りの同型実装、既存テストの正確なpathと実行方式、fixture・DB初期化、検証commandをDeepSeekの`survey`へ委任する。reportだけで[agent_name]がシナリオ設計とテスト資産の作成を完了できるよう、次の調査パケットを返させる。

- 重要な根拠の`file:line`と、判断に必要な最小限の抜粋
- import元、export名、関数signature、型、enum・定数の実値
- 最寄りの既存test・helper・fixture・seedの接続方法と、模倣に必要な構造
- DB model・table・列型、日付と時刻の扱い、外部境界の観測方法
- 実在する検証command、cwd、必要な環境・guard・初期化順
- 読めなかったpath、未確認事項、推測を分けた残件一覧

各commandを`target-test`、`direct-regression`、`typecheck`、`schema`へ分類し、対象pathと理由を返させる。DeepSeekにはテストシナリオ、期待値、assertion、fixture構成、テストコードを提案または変更させない。
DeepSeekへ委任する前に`bash [skills_root]/deepseek/delegate.sh prepare`を実行し、hookが注入した共通契約を反映する。`survey`と`implement`は必ず`bash [skills_root]/deepseek/delegate.sh <mode>`で実行する。

[agent_name]はsurvey前後を問わず探索禁止区間の対象を通常探索しない。`result.json`で正常終了を確認し、`report.md`の残件一覧が空で、承認シナリオとテスト資産の作成に必要な調査パケットが揃った場合だけ次へ進む。不足があれば調査項目を絞った新しいsurveyへ戻す。正常終了したが不完全なreportを、[agent_name]のRead / Grep / Glob / shell検索で補完してはならない。直接調査は探索禁止区間で定めたfallbackまたは具体的疑義の限定検証に限る。

設計書とsurveyが集めた事実を根拠に、[agent_name]が正常系、境界値、異常系、副作用、回帰リスクとテスト構造を設計して提示する。既存テストを正解として模倣せず、承認されるまでファイルを変更しない。`schema.prisma`だけの変更ではsurvey結果から既存schema patternと検証commandを確定するが、シナリオ承認は要求しない。

### 3. [agent_name]がテストを書く

承認済みシナリオと受領済みの調査パケットだけをテストへ変換する。変更対象のテスト資産と自分が書いた内容は読んでよいが、importやfixtureを確かめるために本体コード、既存基盤、同型testを検索・再読してはならない。足りない事実は限定surveyで補う。追跡対象のファイルは1ファイルずつ即コミットする。無視されたテスト資産は `git add -f` / `git add --force` を使わず、作業ツリーに残して検証と後続工程を継続する。テストの意味を変えるために既存assertionを弱めてはならない。

`.jsx` / `.tsx` componentとReact hookには隣接unit testを作らず、テスト資産の必須対象にも数えない。承認済みシナリオが画面挙動を要求する場合は既存のintegration / E2E境界で検証し、そのためだけにcomponentまたはhookのunit testを新設しない。

### 4. Redを確認する

対象テストをプロジェクトのtest script経由で実行し、実装不足または期待値との差で失敗することを確認する。

- syntax/import/typeの失敗は、シナリオを変えず[agent_name]が修正する
- syntax/import/typeの修正に未調査のリポジトリ事実が必要なら、直接探索せず限定surveyへ戻す
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

設計書の完了条件、Step 8の検証、レビュー、追跡対象のコミットを確認してから、`bash [skills_root]/polish/capture-scope.sh list-changed <機能名>`を実行する。開始scope全件ではなく、この出力にある実変更pathだけをまとめて`polish`へ渡し、ファイルごとには呼ばない。`polish`は同じ決定的selectorで入力を再検証し、formatter・lint・`unwind`を実変更pathだけへ適用する。決定的toolの自動修正を必要範囲だけ再確認し、上位モデルによる判断修正後は全品質ゲートを先頭から反復してから返る。

`from-prompt`では、polishが現在のHEADへquality receiptを記録した後だけ次を単独実行する。失敗時はindexを直接編集しない。

```bash
bash [skills_root]/tdd/mark-prompt-done.sh <機能名>
```

設計書path modeでは完了receiptと`mark-prompt-done.sh`を使わず、indexへ触れない。開始receiptを使うscope path検査は両modeで実行する。

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
