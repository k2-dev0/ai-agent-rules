---
name: tdd
description: ユーザーが `$tdd from-prompt` または `$tdd <承認済み設計書path>` を明示し、設計書1枚をworkerによる調査・初回実装、上位モデルのシナリオ承認・テスト・レビュー・修正、polishまで実行するときに使う。from-promptだけ実装順indexを更新する。
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

承認済み設計書1枚を`survey → scenario → red → delegated-green → review-green → polish`で完了する。調査後のシナリオ、テスト、Red、worker初回実装、Greenは[シナリオ駆動の共通実装フロー](SCENARIO_FLOW.md)を全文読んで正本とし、このスキルでは設計書選択、探索制限、scope固定、polish、index更新だけを追加する。

## 入力mode

先頭引数を次のどちらかに限定する。引数なし、追加引数、存在しないpathでは変更せず`invalid_scope`を返す。

| mode | 対象 | 完了時のindex更新 |
|---|---|---|
| `from-prompt` | `@.[agent_name]/prompt/.prompt.md`の先頭の`- [ ] branch-<機能名>-prompt.md`だけ。他の設計書は読まない | 同じ行だけを`[x]`へ変更する |
| `<承認済み設計書path>` | 指定された既存Markdown 1枚だけ | indexを探索・変更しない |

`from-prompt`でindexがない、空、参照先がない場合は変更せず停止する。未完了項目がなければ全設計書が完了済みと報告する。どちらのmodeも設計書1枚を1 branch・1 PRの単位として扱い、次の設計書へ自動で進まない。

## 権限境界

| 対象 | [agent_name] | worker |
|---|---|---|
| テストシナリオ設計 | 可 | 禁止。既存テストの事実報告だけ可 |
| テスト資産の変更 | 承認済みシナリオ内だけ可 | 禁止 |
| 設計資産の変更 | cowlickの承認後だけ可 | 禁止 |
| 本体コード、schema、rules、既存テスト基盤、同型実装の探索 | fallback条件成立後、または具体的疑義の限定検証だけ可 | 可 |
| 許可された本体コードと`schema.prisma`の初回実装 | workerの2回連続応答失敗または認証失敗後だけ可 | 可 |
| worker候補反映後の本体コード修正 | 可 | 禁止 |
| テスト実行・レビュー・Git | 可 | 禁止 |

テスト資産にはtest/spec、fixture、factory、mock、stub、fake、snapshot、golden file、テスト設定、CI上のテスト実行設定を含める。

## 探索禁止区間

設計書を選んでから共通フローでworkerの初回実装候補を受領するまで、[agent_name]が直接読めるリポジトリ内ファイルを次に限定する。

- 対象設計書1枚と`from-prompt`で必要なindex 1枚
- 今回変更するテスト資産そのもの
- workerが返した`result.json`、`report.md`、`candidate.patch`、`opencode.jsonl`
- [agent_name]自身がこの実行で作成したファイル

この区間では、本体コード、`schema.prisma`、rules、package・test設定、既存helper・fixture・seed、同型実装をRead / Grep / Glob / Explorer / `rg` / `grep` / `sed` / `cat` / `git show`などで通常調査しない。workerの`file:line`はreportの監査根拠であって全件再読の許可ではない。import、型、列名、fixture形式、実行commandが足りなければ、推測や直接確認をせず限定surveyへ戻す。テスト実行のdiagnosticと、[agent_name]が変更するテスト資産の読み直しは探索に含めない。

[agent_name]が直接調査へ切り替えてよいのは次だけとする。

1. 共通委任契約の応答失敗・認証失敗によるfallback条件が成立した
2. [agent_name]またはユーザーがreportの特定claimへ具体的な疑義を示した

疑義にはreport内の矛盾、根拠行の欠落、設計書との不一致、test diagnosticとclaimの衝突を含む。単なる情報不足や「念のため」は疑義に含めず限定surveyへ戻す。疑義を検証するときは、疑わしいclaim、疑義の根拠、読むpathまたは範囲を先にユーザーへ明示し、その確認に必要な最小範囲だけを直接読む。正常終了したが不完全なreportを[agent_name]のRead / Grep / Glob / shell検索で補完しない。

## 実行フロー

### 1. 対象と変更範囲を確定する

選んだ設計書の対象ファイルを、テスト資産、workerへ渡す本体コードと`schema.prisma`、その他の保護対象へ分類する。委任対象pathまたは変更予定のテスト資産に未コミット変更があれば停止する。

機能名と、今回変更する本体コードおよび`schema.prisma`の相対pathを確定し、変更前に次を1回実行する。新規pathはまだ存在しなくてよい。設計書path modeの機能名は`branch-<機能名>-prompt.md`から得る。

```bash
bash [skills_root]/polish/capture-scope.sh <機能名> -- <相対path>...
```

これはpolishが使う基準commitと候補pathを固定するだけで品質検査は行わない。開始前から対象pathがdirtyなら停止し、後から対象pathを推測追加しない。

### 2. 調査を委任する

workerへ委任する前に`bash [skills_root]/worker/delegate.sh prepare`を実行し、hookが注入した共通契約を反映する。`survey`と`implement`は必ず`bash [skills_root]/worker/delegate.sh <mode>`で実行する。

設計書を要求根拠としてworkerの`survey`へ委任し、共通フローの必須調査パケットを返させる。[agent_name]はsurvey前後を問わず探索禁止区間の対象を通常探索しない。`result.json`が正常終了し、`report.md`の残件一覧が空で、調査パケットが揃った場合だけ進む。不足は項目を絞った新しいsurveyへ戻す。

### 3. 共通のシナリオ駆動実装フローを完了する

共通フローのStep 1〜7を順に実行する。要求根拠は承認済み設計書とsurvey、worker modeは`implement`、workerへの入力は設計書、Redの要約、許可pathとする。`schema.prisma`だけの変更、component・React hookのテスト境界、シナリオ再承認、相談、候補採否、Greenはすべて共通フローに従う。

### 4. polishと完了処理を行う

設計書の完了条件、共通フローのGreen、レビュー、追跡対象のコミットを確認してから、`bash [skills_root]/polish/capture-scope.sh list-changed <機能名>`を実行する。開始scope全件ではなく、この出力にある実変更pathだけをまとめて`polish`へ渡し、ファイルごとには呼ばない。`polish`はformatter・lint・`unwind`を実変更pathだけへ適用し、最後のscope path検査で入力の完全一致とtracked・cleanを確認する。formatterの自動修正は必要範囲だけ再確認し、上位モデルがコードを判断して修正した場合は全品質ゲートを先頭から再実行する。

`from-prompt`では、polishのscope path検査が成功した後だけ次を単独実行する。失敗時はindexを直接編集しない。

```bash
bash [skills_root]/tdd/mark-prompt-done.sh <機能名>
```

設計書path modeでは`mark-prompt-done.sh`を使わず、indexへ触れない。開始receiptを使うscope path検査は両modeで実行する。

## 例外停止

- 共通委任契約が停止対象とする予算、ZDR、依存commandの問題がある
- workerが許可外pathを変更した
- ユーザーの未コミット変更と対象pathが衝突する
- 2回の応答失敗後も上位モデルの実装経路を利用できない
- DB、依存関係、公開APIなど承認範囲外の変更が必要になる

## 完了条件

- 承認済みシナリオがすべてGreen
- 共通フローとpolishの検証が成功
- [agent_name]が差分をレビュー済み
- 追跡対象の変更が1ファイルずつコミット済み
- 無視された対象変更は作業ツリー上で検証済みで、未コミット理由を完了報告へ含めた
- `from-prompt`ではpolishのscope path検査後にindexを更新した

対象設計書、承認シナリオ、Red、Green、workerの相談・採否理由・survey / implement / nestingのtask-id、polish結果、コミットを完了報告へ含める。`from-prompt`ではindexの残件数も含める。
