---
name: errand
description: "ユーザーが $errand を明示し、設計書を作らず、既存パターンから一意に決まる小さな本体コード修正・定型ファイル追加・Prisma schema追加を、worker調査、テストシナリオ選択、テスト、Red、専用subagent初回実装、Greenまで完了したいときだけ使う。複数ファイルを扱えるが、新機能設計、要件判断、設定・migration・依存関係の変更には使わない。"
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/require-test.sh
---

## 目的

設計書を作る価値がないほど小さく、依頼と最寄りの既存パターンから変更内容・対象path・完了条件を一意に確定できる実装を、`survey → scenario → red → subagent-green → review-green`で完了する。新しいテストが必要でも停止せず、[agent_name]がテストシナリオ候補を提示し、ユーザーが選択したものだけをテストへ変換する。workerは読み取り調査、implementerは制限された初回実装、上位モデルは要件の縮約、シナリオ・テスト、許可path、差分の採否・修正、検証、Gitを担当する。

開始時に[シナリオ駆動の共通実装フロー](../tdd/SCENARIO_FLOW.md)を全文読み、調査パケット、テストシナリオ選択、Red、初回実装、Greenの正本として従う。

## 初回実装と修正の境界

- 初回実装とは、このerrandで依頼された挙動について許可pathへ最初に加える本体コード変更を指す
- 初回実装は専用`implementer` subagentがactive scope内へ直接作る。上位モデルが最初の応答前にstub、雛形、部分実装、手作業の代替実装を作らない
- implementerの初回実装後は、上位モデルがユーザー依頼の全要件、test_scenarios、テスト、型検査、lintの結果に基づいて直接修正する。修正をworkerまたはimplementerへ再委任しない
- implementerが未変更のまま中断・無応答なら、cleanな許可pathに限り一度だけ再起動する。再実行も失敗した場合だけ上位モデルが初回実装を引き継ぐ
- 修正する／しない、部分採用、全体拒否の判断は上位モデルが行う

## 起動境界

ユーザーが明示的にerrandを呼んだ場合だけ使う。通常の自然言語依頼から自動起動せず、meeting / cowlick / ponytail / tddは呼ばない。

次のいずれかなら、変更せず理由を報告して停止する。新しいテストまたはテストファイルが必要なことは停止理由にしない。

- 要件、公開挙動、対象path、完了条件のいずれかを依頼と既存パターンから一意に決められない
- シナリオを作るために新しいAPI、認可境界、データ契約などの設計判断が必要になる
- migration、設定、依存関係、CI、スキル、Git管理ファイルを変更する
- 許可pathまたは変更予定のテスト資産に未コミット変更がある

対象ファイルが未実装、複数、または対応テストが未作成であることだけを理由に停止しない。単一の公開挙動について同じ既存パターンから各変更を一意に決められる限り、複数の本体コードと`schema.prisma`を一つのerrandで扱う。Prisma modelのフィールド、型、主キー、relationを依頼または同型実装から一意に決められない場合は停止する。migration fileの作成と`prisma migrate`・`prisma db push`・`prisma db execute`は常に禁止する。

## 実行手順

workerへ委任する前に`bash [skills_root]/worker/delegate.sh prepare`を実行し、hookが注入した共通契約を反映する。`survey`は必ず`bash [skills_root]/worker/delegate.sh survey`で実行する。

1. 依頼から公開挙動、完了条件、既知の識別子・機能語を探索anchorとして固定する。候補pathを得るためにproduction fileを読まない。依頼にある識別子、path、番号、固有名詞を省略・翻訳・一般化しない。
2. 必要な事実ごとにworkerの`survey`を別task-idで実行し、共通契約のvalidatorを通る`C1` 1件だけのJSONを渡す。現在の対象挙動、最寄りの同型実装1件、置換する要素、test・schema境界を同じtaskへ混ぜない。旧branch・tag・commitを読むsurveyには`--source-ref <revision>`を付け、現在HEADの調査と分ける。今回不要なruntime、schedule、handler、HTTP、設定、DB、schema、test基盤、検証commandをexcludeへ明記する。
3. `errand-<短い機能名>`形式のASCII kebab-case scope名を一つ固定する。次がすべて一意なら続け、一つでも欠ければ変更せず停止する。
   - 依頼後の公開挙動と完了条件
   - 最寄りの同型実装1件の正確なpath
   - 同型実装から置き換える識別子・値の対応
   - cleanな本体コード・schema・テスト資産の候補path一覧
   - 共通フローで使う既存の検証command
4. 許可する本体コードと`schema.prisma`を次でscopeへ固定する。その後、共通フローのStep 1〜3を実行し、[agent_name]がテストシナリオ候補をまとめて提示してユーザーが選択した後、選択されたものだけをテストへ変換してRedを確認する。test除外pathだけの変更は共通フローの例外に従う。
   ```bash
   bash [skills_root]/polish/capture-scope.sh <scope名> -- <相対path>...
   ```
5. ユーザー依頼の全要件、Redのcommandと期待した理由での失敗要約、survey結果から短い実装指示を作る。test_scenariosの採否で実装指示を削らない。許可pathは検証済みsurveyが返したcleanな本体コードと`schema.prisma`、または既存の親directory内で同型実装から名前・内容を一意に決められる新規本体ファイルだけにする。
6. 共通フローのStep 4〜8を完了する。implementerへ判断に使った検証済みsurvey task-idとartifact pathを全件渡し、列名、型幅、relationなどを短い指示だけから再推測させない。implementerにテスト、設定、migration、Git、設計資産を変更させない。
7. 共通フローのGreenに加え、path指定可能な既存lintを実行する。利用可能なcommandがなければ発明せず、未実行として報告する。test除外pathだけの依頼でtestを探索・実行せず、検証失敗は共通フローどおりscopeへ帰属させる。

ユーザーが設定やmigration fileなどerrand禁止対象の変更を明示した場合は、`errand`を終了して通常実装へ移ることを一文で宣言する。明示された範囲だけを通常実装として扱い、禁止対象をworkerへ委任しない。

## 完了報告

依頼、選択済みtest_scenarios、Red、Green、workerのsurvey task-id、implementerの結果、許可path、実装差分の採否、実行した検証と`scope-related` / `unrelated` / `uncertain` / `not run`の分類、コミットを簡潔に報告して停止する。対象外の失敗だけでタスクを未完了と決めない。
