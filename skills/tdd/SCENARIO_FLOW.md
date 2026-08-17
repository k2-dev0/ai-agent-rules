# シナリオ駆動の共通実装フロー

`tdd`と`errand`は、調査後の実装をこの契約へ集約する。呼び出し元のSKILL.mdが入力範囲と停止条件を決め、この文書をシナリオ・テスト・初回実装・Greenの正本とする。

## 呼び出し元が渡すもの

| 入力 | `tdd` | `errand` |
|---|---|---|
| 要求根拠 | 承認済み設計書とsurvey | ユーザー依頼とsurvey |
| worker mode | `implement` | `errand` |
| workerへの実装入力 | 設計書、Redの要約、許可path | 承認済みシナリオを含む短い実装指示、Redの要約、許可path |
| 実装後の追加処理 | polishと必要ならindex更新 | 呼び出し元が定めた限定検証と完了報告 |

workerへ渡せるのはcleanな本体コードと`schema.prisma`だけとする。test/spec、fixture、factory、mock、stub、fake、snapshot、golden file、Markdown、設定、依存関係、migration、Git管理ファイルは渡さない。

## 必須の調査パケット

実装前のsurveyでは、共通委任契約のvalidatorを通る最大4 claimのJSONを渡し、同じIDのclaim-evidenceだけを返させる。一つのclaimへ現在挙動、同型実装、schema、test、検証commandを混ぜない。`evidence.md`だけで[agent_name]がシナリオとテスト資産を作れなければ完了ではない。

- 変更対象の現在の挙動・型・保存先
- 最寄りの同型実装1件と置換する識別子・値
- 今回の入力、schema、設定、test資産のうち実装判断に直接必要な境界
- 対象へ直接使う既存検証command
- 読めなかったpath、未確認事項、推測を分けたRemaining

上の分類を毎回すべて要求しない。たとえば既存列への値の入れ替えなら、現在の生成方法、同型実装1件、入力mapの存在、列型の4 claimで止め、schedule、handler、HTTP、全test基盤、無関係なDB model、全command、runtime・初期化順を除外する。検証commandがclaimに含まれる場合だけ`target-test`、`direct-regression`、`typecheck`、`schema`へ分類し、対象pathと理由を付ける。workerにはシナリオ、期待値、assertion、fixture構成、テストコードを提案または変更させない。`status: 0`でも指定claimが足りなければ、`--supplement-of`で欠落IDだけを補完する。形式だけが壊れた場合は`--repair-of`で再調査せず直す。情報補完は2回、初回を含め合計3回までとする。

初回surveyへproduction pathを渡すための事前Readは行わない。ユーザー入力、承認済み設計書、既知の識別子・機能語を探索anchorとして渡し、実装の許可pathは検証済みsurveyまたは承認済み設計書から得る。

## 1. シナリオを一括承認する

[agent_name]が要求根拠と調査パケットから、今回の公開挙動に必要な正常系、境界値、異常系、副作用、回帰リスクを選び、各シナリオの前提・操作・期待結果を一括提示する。既存テストを正解として盲目的に模倣しない。ユーザーが明示的に承認するまでファイルを変更しない。

次はシナリオ変更なので再承認する。

- 期待結果または前提条件を変える
- シナリオを追加、削除、統合する
- 検証対象の責務や公開挙動を変える

承認済みシナリオを忠実に表すためのimport、型、構文、テスト構造の修正は再承認しない。新しいテストが必要であることだけを理由に停止しない。要求から公開挙動を一意に決められず、新しい設計判断が必要な場合だけ呼び出し元の停止条件へ戻る。

`schema.prisma`だけの変更では公開挙動のtest/specとRed/Greenを要求せず、シナリオ承認も省略する。同じ依頼に本体コードの公開挙動変更が含まれる場合、その挙動は通常どおりシナリオ、Red、Greenの対象にする。

## 2. [agent_name]がテストを書く

承認済みシナリオと調査パケットをテスト資産へ変換する。テストの意味を変えるために既存assertionを弱めない。追跡対象は1ファイルずつ即コミットする。無視されたテスト資産は`git add -f`や`git add --force`を使わず、作業ツリー上で検証する。

`.jsx` / `.tsx` componentとReact hookには、そのためだけの隣接unit testを新設しない。画面挙動は既存のintegration / E2E境界で検証する。

## 3. Redを確認する

対象テストをプロジェクトの既存test script経由で実行し、実装不足または期待値との差で失敗することを確認する。

- syntax、import、型の失敗はシナリオを変えず[agent_name]が修正する
- 未調査のリポジトリ事実が必要なら限定surveyへ戻す
- 最初からGreenなら、テストが要求を検出できるか確認する
- シナリオの変更が必要ならStep 1へ戻して再承認する

## 4. workerへ初回実装を委任する

呼び出し元が指定したmodeへ、実装入力、承認済みシナリオID、Redのcommandと期待した理由での失敗要約、許可pathを渡す。`implement`は`--red-summary`を省略しない。workerにはshell、Git、外部通信、テスト・設計・設定の編集を許可しない。[agent_name]はworkerの最初の応答前にstub、雛形、部分実装を作らず、共通委任契約のfallback条件を満たした場合だけ初回実装を引き継ぐ。

## 5. 相談を処理する

workerがテストの穴、矛盾、曖昧さ、偽陽性・偽陰性を報告した場合は[agent_name]が処理する。

- 承認済み内容から一意に解決できる: 回答し、新しいtask-idで再委任する
- 非ブロッキングな改善案: 記録して続行する
- 新しい設計判断またはシナリオ変更が必要: Step 1へ戻す

workerには発言権だけを認め、テスト・設計の編集権と決定権は与えない。

## 6. 候補パッチを検証して反映する

`result.json`、`opencode.jsonl`、`candidate.patch`を読み、自己申告ではなく実際のパッチを正とする。次を確認する。

- 変更が許可path内だけである
- テスト資産、設計、設定、Gitを変更していない
- テスト環境検出、値のハードコード、assertion攻略がない
- 承認済みシナリオと、`tdd`では承認済み設計にも一致する

採否は上位モデルのレビュー責務とする。安全に修正できる問題は候補を土台に[agent_name]が直接直す。パッチ全体を拒否してもworkerへレビュー・修正を戻さず、承認済み範囲を[agent_name]が完成させる。追跡対象の本体変更は1ファイルずつ即コミットする。

## 7. Green・レビュー・修正を完了する

次を上から実行し、無関係なpackageのtestやproject全体のtestを追加しない。

| 条件 | 実行 |
|---|---|
| 承認済みシナリオから作ったtest | 全件 |
| surveyが`direct-regression`として返した既存test | 全件 |
| TypeScript / JavaScriptを変更 | 所属packageの既存typecheck。なければ`tsc -p <tsconfig> --noEmit` |
| `schema.prisma`を変更 | 所属packageのPrisma `format`、`validate`、`generate` |
| 呼び出し元の完了条件に追加commandがある | そのcommand |

利用可能なcommandがなければ発明せず、未実行として報告する。候補反映後は[agent_name]が差分をレビューし、承認済み範囲へ合わせる本体コード修正を直接行う。通常の修正をworkerへ再委任しない。テストまたはシナリオを変える必要が出た場合だけStep 1へ戻る。
