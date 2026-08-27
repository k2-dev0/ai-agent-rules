---
name: tdd
description: ユーザーが引数なしの`$tdd`を明示し、`@.[agent_name]/prompt/.prompt.md`の先頭未完了設計書1枚をworkerによる調査、ユーザーによるテストシナリオ選択、専用subagentによる初回実装、上位モデルのテスト・レビュー・修正、polishまで実行するときに使う。
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

`.prompt.md`の先頭未完了設計書1枚を`survey → scenario → red → subagent-green → review-green → polish`で完了する。調査後のシナリオ、テスト、Red、専用subagentの初回実装、Greenは[シナリオ駆動の共通実装フロー](SCENARIO_FLOW.md)を全文読んで正本とし、このスキルでは設計書選択、探索制限、scope固定、polish、index更新だけを追加する。

共通フローのStep 0を対象選択より先に実行する。最初のshell commandは`bash [skills_root]/polish/capture-scope.sh status`に固定し、active scopeがあっても復旧調査用workerを起動しない。回収可能なら同じrequestを`recover-to-parent`で引き継ぎ、回収不能なら通常探索を始めず停止する。

## 対象の選択

`$tdd` は引数を受け取らない。`@.[agent_name]/prompt/.prompt.md`の先頭の`- [ ] branch-<機能名>-prompt.md`だけを対象にし、他の設計書は読まない。引数がある、indexがない、未完了項目がない、または参照先がない場合は変更せず停止する。

未完了項目がなければ全設計書が完了済みと報告する。対象設計書は1 branch・1 PRの単位として扱い、次の設計書へ自動で進まない。

## 権限境界

| 対象 | [agent_name] | worker | implementer |
|---|---|---|---|
| テストシナリオ設計 | 可 | 禁止。既存テストの事実報告だけ可 | 禁止 |
| テスト資産の変更 | ユーザーが選択したtest_scenarios内だけ可 | 禁止 | 禁止 |
| 設計資産の変更 | meetingで作成・更新したprompt正本だけ可 | 禁止 | 禁止 |
| 本体コード、schema、rules、既存テスト基盤、同型実装の探索 | fallback条件成立後、または具体的疑義の限定検証だけ可 | 読み取り専用で可 | 許可pathと明示された根拠だけ可 |
| 許可された本体コードと`schema.prisma`の初回実装 | subagentが利用不能またはcleanな再実行も失敗した場合だけ可 | 禁止 | 可 |
| 初回実装後の本体コード修正 | 可 | 禁止 | 禁止 |
| テスト実行・レビュー・Git | 可 | 禁止 | 禁止 |

テスト資産にはtest/spec、fixture、factory、mock、stub、fake、snapshot、golden file、テスト設定、CI上のテスト実行設定を含める。

## 探索禁止区間

設計書を選んでから共通フローでimplementerの初回実装を受領するまで、[agent_name]が直接読めるリポジトリ内ファイルを次に限定する。

- 対象設計書1枚とindex 1枚
- 今回変更するテスト資産そのもの
- workerが返した`result.json`、`report.md`、`evidence.md`、`opencode.jsonl`
- [agent_name]自身がこの実行で作成したファイル

この区間では、本体コード、`schema.prisma`、rules、package・test設定、既存helper・fixture・seed、同型実装をRead / Grep / Glob / Explorer / `rg` / `grep` / `sed` / `cat` / `git show`などで通常調査しない。`evidence_status: verified`のコードがclaimを直接支え、blobが現在も一致する場合は同じ箇所を再読しない。import、型、列名、fixture形式、実行commandが足りなければ、推測や直接確認をせず欠落IDの限定surveyへ戻す。テスト実行のdiagnosticと、[agent_name]が変更するテスト資産の読み直しは探索に含めない。

[agent_name]が直接調査へ切り替えてよいのは次だけとする。

1. 共通委任契約の応答失敗・認証失敗によるfallback条件が成立した
2. worker snapshotに入らない未コミット状態、生成物、runtime・外部状態が対象である
3. 情報調査が初回と補完2回の合計3回に達しても必須情報が不足した、または共通契約どおり再試行しても委任経路が利用不能である
4. 高リスク判断で独立確認そのものが必要、またはユーザーが上位モデル自身の確認を明示した

report内の矛盾、evidence欠落、claimと抽出コードの不一致、snapshot不一致、設計書との不一致、test diagnosticとの衝突は、欠落claim、既存evidenceで足りない理由、追加境界を指定し、`--supplement-of`で初回を含む合計3回まで限定surveyを行う。3回目までは保存範囲の不足自体を直接確認の理由にしない。直接確認するときは理由と再surveyより有利な理由を残し、`evidence.md`または既知の行範囲だけを読む。全file Read、path発見のためのRead、正常終了した不完全reportの通常探索による補完は禁止する。

## 実行フロー

### 1. 対象と変更範囲を確定する

選んだ設計書の対象ファイルを、テスト資産、implementerへ許可する本体コードと`schema.prisma`、その他の保護対象へ分類する。許可pathまたは変更予定のテスト資産に未コミット変更があれば停止する。

機能名と、今回変更する本体コードおよび`schema.prisma`の相対pathを現在の設計書または検証済みsurveyから確定し、変更前に次を1回実行する。pathを得るためにproduction fileを読まない。新規pathはまだ存在しなくてよい。機能名は`branch-<機能名>-prompt.md`から得る。

```bash
bash [skills_root]/polish/capture-scope.sh <機能名> -- <相対path>...
```

これはpolishが使う基準commitと候補pathを固定するだけで品質検査は行わない。開始前から対象pathがdirtyなら停止し、後から対象pathを推測追加しない。

### 2. 調査を委任する

workerへ委任する前に`bash [skills_root]/worker/delegate.sh prepare`を実行し、hookが注入した共通契約を反映する。`survey`は必ず`bash [skills_root]/worker/delegate.sh survey`で実行する。

設計書を要求根拠としてworkerの`survey`へ委任する。各claimは一つの事実に保ち、同じsource refと候補file群を読むclaimだけをvalidator上限の3件まで同じJSONへまとめる。異なるfile群、旧revision、`test_absence`は別task-idにし、独立packetは最大3件を同時に起動する。旧revisionは`--source-ref`で現在HEADと分ける。[agent_name]はsurvey前後を問わず探索禁止区間の対象を通常探索しない。共通契約の成功条件を満たし、残件が空で、指定したclaimが揃った場合だけ進む。不足は`next-action: supplement`に従って欠落claimの境界だけを補完し、`next-action: repair`の場合だけEvidenceのpath・行・件数を変えず形式修正する。

### 3. 共通のシナリオ駆動実装フローを完了する

共通フローのStep 1〜8を順に実行する。要求根拠は承認済み設計書とsurvey、implementerへの入力は共通フローのvalidatorを通した実装request JSONとする。設計書、全要件を保持した実装指示、Evidence、test_scenarios、Redの要約、許可pathをJSONから省略しない。test_scenariosはテスト範囲だけを表し、設計書の実装範囲を狭めない。test除外pathだけの変更、component・React hookのテスト境界、シナリオ再承認、相談、差分採否、Green、失敗のscope帰属はすべて共通フローに従う。

### 4. polishと完了処理を行う

設計書の完了条件、共通フローのGreenまたはtest除外、レビュー、追跡対象のコミットを確認してから、`bash [skills_root]/polish/capture-scope.sh list-changed <機能名>`を実行する。開始scope全件ではなく、この出力にある実変更pathだけをまとめて`polish`へ渡し、ファイルごとには呼ばない。`polish`はformatter・lint・`unwind`を実変更pathだけへ適用し、最後のscope path検査で入力の完全一致とtracked・cleanを確認する。formatterの自動修正は必要範囲だけ再確認し、上位モデルがコードを判断して修正した場合は全品質ゲートを先頭から再実行する。

実装差分、scopeへ帰属した検証結果、`unrelated`・`uncertain`・`not run`を先にユーザーへ報告し、完了マークを付けるか明示的に確認する。検証の成否から[agent_name]が自動判定しない。ユーザーが付けると回答した場合だけ次を単独実行する。

```bash
bash [skills_root]/tdd/mark-prompt-done.sh <機能名>
```

開始receiptを使うscope path検査を実行する。

## 例外停止

- 共通委任契約が停止対象とする予算、ZDR、依存commandの問題がある
- implementerの起動中にscope hookが不完全または無効だった
- ユーザーの未コミット変更と対象pathが衝突する
- handoff後も親sessionが許可pathを変更できない、またはactive requestを維持できない
- DB、依存関係、公開APIなど承認範囲外の変更が必要になる

## 完了報告

- 選択済みtest_scenariosのGreen / `scope fail`、またはtest除外を報告済み
- 共通フローとpolishの各結果がscopeへ帰属済み
- [agent_name]が差分をレビュー済み
- 追跡対象の変更が1ファイルずつコミット済み
- 無視された対象変更は作業ツリー上で検証済みで、未コミット理由を完了報告へ含めた
- 検証結果の報告後に完了マークの判断をユーザーへ委ね、明示的に依頼された場合だけindexを更新した

対象設計書、選択済みtest_scenarios、Red、Green、workerのsurvey / nesting task-id、implementerの相談・差分採否理由、polish結果、コミット、indexの残件数を完了報告へ含める。
