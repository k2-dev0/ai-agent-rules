---
name: errand
description: "ユーザーが $errand を明示し、設計書を作らず、既存パターンから一意に決まる小さな本体コード修正・定型ファイル追加・Prisma schema追加を、シナリオ承認、テスト、Red、worker初回実装、Greenまで完了したいときだけ使う。複数ファイルを扱えるが、新機能設計、要件判断、設定・migration・依存関係の変更には使わない。"
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

設計書を作る価値がないほど小さく、依頼と最寄りの既存パターンから変更内容・対象path・完了条件を一意に確定できる実装を、`survey → scenario → red → delegated-green → review-green`で完了する。新しいテストが必要でも停止せず、[agent_name]がシナリオを設計してユーザー承認後にテストを書く。workerは調査と制限された初回実装、上位モデルは要件の縮約、シナリオ・テスト、許可path、候補の採否・修正、検証、Gitを担当する。

開始時に[シナリオ駆動の共通実装フロー](../tdd/SCENARIO_FLOW.md)を全文読み、調査パケット、シナリオ承認、Red、初回実装、Greenの正本として従う。

## 初回実装と修正の境界

- 初回実装とは、このerrandで依頼された挙動について許可pathへ最初に加える本体コード変更を指す
- 初回実装はworkerの`candidate.patch`から始める。上位モデルが最初の応答前にstub、雛形、部分実装、手作業の代替実装を作らない
- worker候補の反映後は、上位モデルが承認済みシナリオ、テスト、型検査、lintの結果に基づいて直接修正する。修正をworkerへ再委任しない
- 候補が未生成、timeout、最終応答欠落なら新しいtask-idで1回だけ再委任する。2回続けて応答に失敗した場合、または明示的な認証失敗があった場合だけ上位モデルが初回実装を引き継ぐ
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

workerへ委任する前に`bash [skills_root]/worker/delegate.sh prepare`を実行し、hookが注入した共通契約を反映する。`survey`と`errand`は必ず`bash [skills_root]/worker/delegate.sh <mode>`で実行する。

1. 依頼から公開挙動、完了条件、候補pathを固定する。識別子、path、番号、固有名詞を省略・翻訳・一般化しない。
2. workerの`survey`を必ず1回実行し、共通フローの必須調査パケット、最寄りの同型実装1件、置換する要素、対象pathを返させる。網羅監査は依頼しない。
3. 次がすべて一意なら続け、一つでも欠ければ変更せず停止する。
   - 依頼後の公開挙動と完了条件
   - 最寄りの同型実装1件の正確なpath
   - 同型実装から置き換える識別子・値の対応
   - cleanな本体コード・schema・テスト資産の候補path一覧
   - 共通フローで使う既存の検証command
4. 共通フローのStep 1〜3を実行し、[agent_name]がシナリオを一括提示して明示承認を得た後、必要なテストを作成してRedを確認する。`schema.prisma`だけの変更は共通フローの例外に従う。
5. 依頼、承認済みシナリオ、Redの要約、survey結果から短い実装指示を作る。許可pathはcleanな本体コードと`schema.prisma`、または既存の親directory内で同型実装から名前・内容を一意に決められる新規本体ファイルだけにする。
6. `errand` modeへ実装指示と`--`以降の許可pathを渡し、共通フローのStep 4〜7を完了する。workerにテスト、設定、migration、Git、設計資産を変更させない。
7. 共通フローのGreenに加え、path指定可能な既存lintを実行する。利用可能なcommandがなければ発明せず、未実行として報告する。

ユーザーが設定やmigration fileなどerrand禁止対象の変更を明示した場合は、`errand`を終了して通常実装へ移ることを一文で宣言する。明示された範囲だけを通常実装として扱い、禁止対象をworkerへ委任しない。

## 完了報告

依頼、承認シナリオ、Red、Green、workerのsurvey / errand task-id、許可path、候補パッチの採否、実行した検証、コミットを簡潔に報告して停止する。
