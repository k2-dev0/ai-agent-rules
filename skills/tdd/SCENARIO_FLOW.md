# シナリオ駆動の共通実装フロー

`tdd`と`errand`は、調査後の実装をこの契約へ集約する。呼び出し元のSKILL.mdが入力範囲と停止条件を決め、この文書をシナリオ・テスト・初回実装・Greenの正本とする。

## 呼び出し元が渡すもの

| 入力 | `tdd` | `errand` |
|---|---|---|
| 要求根拠 | 承認済み設計書とsurvey | ユーザー依頼とsurvey |
| 実装subagentへの入力 | 設計書、Evidence、承認済みシナリオ、Redの要約、許可path | 承認済みシナリオを含む短い実装指示、Evidence、Redの要約、許可path |
| scope名 | 設計書の機能名 | 呼び出し元が固定するASCII kebab-case名 |
| 実装後の追加処理 | polishと必要ならindex更新 | 呼び出し元が定めた限定検証と完了報告 |

実装subagentへ許可できる変更先はcleanな本体コードと`schema.prisma`だけとする。test/spec、fixture、factory、mock、stub、fake、snapshot、golden file、Markdown、設定、依存関係、migration、Git管理ファイルは許可pathに含めない。

## 必須の調査パケット

実装前のsurveyでは、共通委任契約のvalidatorを通る`C1` 1件だけのJSONをtask-idごとに渡す。現在挙動、同型実装、schema、test、検証commandを別taskへ分ける。旧revisionを読むtaskには`--source-ref <revision>`を付け、現在HEADと同じtaskで比較しない。`evidence.md`だけで[agent_name]がシナリオとテスト資産を作れなければ完了ではない。

- 変更対象の現在の挙動・型・保存先
- 最寄りの同型実装1件と置換する識別子・値
- 今回の入力、schema、設定、test資産のうち実装判断に直接必要な境界
- 対象へ直接使う既存検証command
- 読めなかったpath、未確認事項、推測を分けたRemaining

上の分類を毎回すべて要求しない。たとえば既存列への値の入れ替えなら、現在の生成方法、同型実装1件、入力mapの存在、列型を必要な順に別task-idで調べる。次の変更判断に不要なclaimは起動しない。検証commandのtaskだけ`target-test`、`direct-regression`、`typecheck`、`schema`へ分類し、対象pathと理由を付ける。workerにはシナリオ、期待値、assertion、fixture構成、テストコードを提案または変更させない。`status: 0`でも`C1`が足りなければ、`--supplement-of`で同じ事実の欠落境界だけを補完する。

初回surveyへproduction pathを渡すための事前Readは行わない。ユーザー入力、承認済み設計書、既知の識別子・機能語を探索anchorとして渡し、実装の許可pathは検証済みsurveyまたは承認済み設計書から得る。

## 1. シナリオを一括承認する

[agent_name]が要求根拠と調査パケットから、今回の公開挙動に必要な正常系、境界値、異常系、副作用、回帰リスクを選び、各シナリオの前提・操作・期待結果を一括提示する。既存テストを正解として盲目的に模倣しない。ユーザーが明示的に承認するまでファイルを変更しない。

次はシナリオ変更なので再承認する。

- 期待結果または前提条件を変える
- シナリオを追加、削除、統合する
- 検証対象の責務や公開挙動を変える

承認済みシナリオを忠実に表すためのimport、型、構文、テスト構造の修正は再承認しない。新しいテストが必要であることだけを理由に停止しない。要求から公開挙動を一意に決められず、新しい設計判断が必要な場合だけ呼び出し元の停止条件へ戻る。

次のtest除外pathだけの変更では対応test/specの作成・実行とRed / Greenを要求せず、シナリオ承認も省略する。実装subagentへの入力には除外pathと理由を明記する。

- `schema.prisma`
- basenameが`constants.ts`または`constants.js`のfile
- `constants/`配下のfile

同じ依頼にそれ以外の本体コードの公開挙動変更が含まれる場合、その挙動だけを通常どおりシナリオ、Red、Greenの対象にする。test除外pathがscopeにあることを理由にtest commandを追加しない。

## 2. [agent_name]がテストを書く

承認済みシナリオと調査パケットをテスト資産へ変換する。テストの意味を変えるために既存assertionを弱めない。追跡対象は1ファイルずつ即コミットする。承認済みtestが`.gitignore`や`.git/info/exclude`でignoredなら、作業ツリー上だけのRedを続行理由にしない。`git add -f`や`git add --force`で回避せず、実装requestを作る前に停止してignore規約の解消をユーザーへ求める。

`.jsx` / `.tsx` componentとReact hookには、そのためだけの隣接unit testを新設しない。画面挙動は既存のintegration / E2E境界で検証する。

## 3. Redを確認する

対象テストをプロジェクトの既存test script経由で実行し、実装不足または期待値との差で失敗することを確認する。

- syntax、import、型の失敗はシナリオを変えず[agent_name]が修正する
- 未調査のリポジトリ事実が必要なら限定surveyへ戻す
- 最初からGreenなら、テストが要求を検出できるか確認する
- シナリオの変更が必要ならStep 1へ戻して再承認する

## 4. 専用subagentへ初回実装を委任する

まず次のschemaで実装request JSONを作る。自然文だけで引き渡さず、worker task、artifact、scenario、Red、scope、許可pathを機械検証できる形にする。

```json
{
  "version": 2,
  "action": "implement",
  "scope": "機能名",
  "spec": ".codex/prompt/branch-example-prompt.md。errandではnull",
  "implementation_instruction": "初回実装として行う変更を命令形で記述",
  "worker_tasks": [
    {"task_id": "task-id", "result": "result.jsonの相対path", "report": "report.mdの相対path", "evidence": "evidence.mdの相対path"}
  ],
  "approved_scenarios": [{"id": "S1", "contract": "前提、操作、期待結果の短い契約"}],
  "test_paths": ["Redに使った追跡済みtestの相対path"],
  "red": {"command": "実行command", "status": 1, "reason": "期待した理由での失敗要約"},
  "test_exemption": null,
  "allowed_paths": ["変更を許可する個別file path"]
}
```

`action`は常に`implement`とし、承認済みIDだけでなく各シナリオの短い契約を`approved_scenarios`へ入れる。`test_paths`は配置場所を推測せず、Redに使った追跡済みtestを列挙する。test除外時だけ`approved_scenarios`と`test_paths`を空配列、`red`を`null`とし、`test_exemption`を`{"paths":[...],"reason":"..."}`にする。次を実行し、成功時にstdoutへ返る正規化済みJSONをそのまま保持する。失敗したrequestを自然文で補ってsubagentを起動しない。

```bash
bash [skills_root]/tdd/validate-implementation-request.sh '<request-json>'
```

検証済みJSONを得たら次を実行して許可pathをactiveにし、`implementer` subagentを一体だけforegroundで起動して完了まで待つ。別の実装subagentを並行起動しない。

```bash
bash [skills_root]/polish/capture-scope.sh activate <scope名>
```

Claude Codeではproject agent `implementer`を使う。Codexではtask名`implementer`、`fork_turns: "none"`、`model: "gpt-5.6-luna"`、`reasoning_effort: "max"`を明示してfresh contextで起動し、`.codex/agents/implementer.toml`を最初に読ませる。full-history forkは禁止する。generic agentへ「named implementer」と名乗らせて代用しない。spawnが返したchild agent IDを保持し、IDが空、waitのreceiverが空、または起動表示が`gpt-5.6-luna max`でなければ実装成功にせず、直ちに中断してscopeを解除する。validatorのstdoutを改変せず渡し、先頭に「これは分類・レビューではなく初回実装である。必要なartifactを読んで許可pathを変更せよ」とだけ付ける。

subagentの完了・中断を確認したら、成功失敗にかかわらず、親が次を実行してscopeを解除する。active中に親がコード変更やshell実行を並行しない。

```bash
bash [skills_root]/polish/capture-scope.sh deactivate <scope名>
```

## 5. 相談を処理する

実装subagentがテストの穴、矛盾、曖昧さ、偽陽性・偽陰性を報告した場合は[agent_name]が処理する。

- 許可pathがすべてcleanで、追加surveyにより一意に解決できる: 必要なsurvey後に同じJSONをvalidatorへ再度通し、activateから一度だけ再実行する。deactivate済みのrequest receiptは再利用できない
- 非ブロッキングな改善案: 記録して続行する
- 新しい設計判断またはシナリオ変更が必要: Step 1へ戻す

`Outcome: implemented`でも許可pathの実差分が0なら実装失敗として扱う。`Outcome: consultation_required`または説明・分類だけを返した場合は相談として処理し、実装成功に数えない。実装subagentが一部でも変更した後は再委任しない。テスト・設計の編集権と決定権は与えない。

## 6. 実装差分を検証する

subagentの自己申告ではなく、共有worktreeの実際の差分を正として次を確認する。scope hookの許可判定だけで内容を採用しない。

- 変更が許可path内だけである
- テスト資産、設計、設定、Gitを変更していない
- テスト環境検出、値のハードコード、assertion攻略がない
- 承認済みシナリオと、`tdd`では承認済み設計にも一致する

正しい処理であることに加え、半年後に負債にならないかを必ずレビューする。短さや抽象度の高さを品質とみなさず、次を確認する。

- 独立した業務責務を持たないhelperや薄いwrapperにより、処理を追うための関数ジャンプが増えていない
- 現在の要件に不要な共通化、汎用化、設定可能性、将来用の拡張点を作らず、YAGNIに従っている
- 制御フローとデータ変換を上から自然に追え、賢すぎる式、暗黙の状態、過長なmethod chainへ畳み込んでいない
- `filter().map()`など複数段に分けると意図が明確になる処理を、短さだけのために`reduce()`一つへ押し込んでいない
- 重複排除や行数削減より、多少冗長でも局所的に理解できる名前と構造を選んでいる

この保守性レビューに通らない差分は、そのまま採用しない。上位モデルが承認済み範囲内で読みやすく直し、Greenと品質ゲートを再実行する。

採否は上位モデルのレビュー責務とする。安全に修正できる問題は差分を土台に[agent_name]が直接直す。差分全体を拒否してもsubagentへレビュー・修正を戻さず、承認済み範囲を[agent_name]が完成させる。subagentが中断・無応答で、cleanな許可pathへの再実行も一度失敗した場合は[agent_name]が初回実装を引き継ぐ。追跡対象の本体変更は1ファイルずつ即コミットする。

## 7. Green・レビュー・修正を完了する

次を上から実行し、無関係なpackageのtestやproject全体のtestを追加しない。

| 条件 | 実行 |
|---|---|
| 承認済みシナリオから作ったtest | 全件 |
| surveyが`direct-regression`として返した既存test | 全件 |
| TypeScript / JavaScriptを変更 | 所属packageの既存typecheck。なければ`tsc -p <tsconfig> --noEmit` |
| `schema.prisma`を変更 | 所属packageのPrisma `format`、`validate`、`generate` |
| 呼び出し元の完了条件に追加commandがある | そのcommand |

承認済みシナリオから作ったtestが無い場合、test除外pathのために既存testを探索・実行しない。利用可能なcommandがなければ発明せず、未実行として報告する。初回実装後は[agent_name]が差分をレビューし、承認済み範囲へ合わせる本体コード修正を直接行う。通常の修正をworkerまたは実装subagentへ再委任しない。テストまたはシナリオを変える必要が出た場合だけStep 1へ戻る。

## 8. 失敗をscopeに帰属させる

test、typecheck、lint、Prisma検証の終了codeだけで今回の成否を決めず、各diagnosticを次へ分類する。

- `scope-related`: 承認済みシナリオの対象test、実変更path自体のdiagnostic、または変更した公開型・export・契約が原因と確認できるcallerの失敗
- `unrelated`: 実変更pathと因果関係がない既存失敗、今回作成・変更していないignored / untracked test、checkout前のbranchの残留testが消えた実装を参照する失敗
- `uncertain`: 診断情報だけで因果関係を確定できない失敗

`scope-related`だけを修正・再検証の対象にする。承認範囲内の修正を尽くしても残る場合は`scope fail`として報告へ進む。`unrelated`はファイルを修正・削除せず、command、diagnostic、対象外と判断した根拠を報告してworkflowを続ける。`uncertain`は推測で緑または赤に倒さずユーザーへ報告する。どの分類が残っていてもそれから完了マークを自動判定せず、判断はユーザーに委ねる。
