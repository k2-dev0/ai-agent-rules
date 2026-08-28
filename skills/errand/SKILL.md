---
name: errand
description: "ユーザーが$errandを明示し、設計書を作らず、既存パターンから一意に決まる小さな本体コード修正・定型ファイル追加・Prisma schema追加を、native調査、テストシナリオ選択、Red、native初回実装、Greenまで完了したいときだけ使う。新機能設計、要件判断、設定・migration・依存関係の変更には使わない。"
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent
disable-model-invocation: true
---

## 目的

設計書を作る価値がないほど小さく、依頼と最寄りの既存パターンから変更内容・完了条件を一意に確定できる実装を、`native survey → scenario → red → native implementer → review-green`で完了する。新しいテストが必要でも停止せず、[agent_name]が候補を提示し、ユーザーが選択したものだけをテストへ変換する。

開始時に[シナリオ駆動の共通実装フロー](../tdd/SCENARIO_FLOW.md)を全文読み、native調査、テストシナリオ選択、Red、初回実装、Greenの正本として従う。

## 初回実装と修正の境界

- 初回実装とは、このerrandで依頼された挙動について最初に加えるproduction code変更を指す
- 初回実装は専用`implementer` subagentが共有worktreeへ直接作る。上位モデルが先にstub、雛形、部分実装を作らない
- implementerの初回実装後は、上位モデルがユーザー依頼の全要件、test_scenarios、テスト、型検査、lintに基づいて直接修正する。修正をsurveyorまたはimplementerへ再委任しない
- implementerが未変更のまま中断・無応答なら、変更前worktreeがcleanな場合だけ一度再起動する。再実行も失敗した場合だけ上位モデルが初回実装を引き継ぐ
- 修正する／しない、部分採用、全体拒否の判断は上位モデルが行う

## 起動境界

ユーザーが明示的にerrandを呼んだ場合だけ使う。通常の自然言語依頼から自動起動せず、meeting / cowlick / ponytail / tddは呼ばない。

次のいずれかなら、変更せず理由を報告して停止する。新しいテストまたはテストファイルが必要なことは停止理由にしない。

- 要件、公開挙動、完了条件のいずれかを依頼と既存パターンから一意に決められない
- シナリオを作るために新しいAPI、認可境界、データ契約などの設計判断が必要になる
- migration、設定、依存関係、CI、スキル、Git管理ファイルを変更する
- Red用testのcommit後もユーザー由来のdirty fileが残る

対象ファイルが未実装、複数、または対応テストが未作成であることだけを理由に停止しない。単一の公開挙動について同じ既存パターンから各変更を一意に決められる限り、複数の本体コードと`schema.prisma`を一つのerrandで扱う。Prisma modelのフィールド、型、主キー、relationを依頼または同型実装から一意に決められない場合は停止する。migration fileの作成と`prisma migrate`・`prisma db push`・`prisma db execute`は常に禁止する。

## native調査

依頼にある識別子、path、番号、固有名詞を省略・翻訳・一般化しない。これらを探索起点にし、native survey subagentへ次を確認させる。

- 対象の現在挙動
- 最寄りの同型実装1件と置換する識別子・値
- 直接関係するschema・test境界
- 既存の検証command

必要な事実をsource group単位へ分け、独立した調査は最大3体を並行起動する。同じfile群を読む事実だけを一体へまとめる。返答には確認済み事実、根拠の`path:line`、想定変更先、test・検証command、未確認事項を含める。packet、claim、Evidence artifact、repair、外部workerは使わない。

必須情報が一つだけ不足した場合は同じsurveyorへ一度だけ限定follow-upする。親は返答を採否し、一意性を確定できなければ変更せず停止する。

## 実行手順

1. 依頼から公開挙動、完了条件、既知の識別子・機能語を固定する。
2. 共通フローのStep 0でnative agentをpreflightし、source groupごとのsurveyorを最大3体起動する。
3. 次がすべて一意なら続け、一つでも欠ければ変更せず停止する。
   - 依頼後の公開挙動と完了条件
   - 最寄りの同型実装1件の正確なpath
   - 同型実装から置き換える識別子・値の対応
   - 想定変更先
   - 既存の検証command
4. 共通フローのStep 1〜3を実行し、[agent_name]がテストシナリオ候補をまとめて提示してユーザーが選択した後、選択されたものだけをテストへ変換してRedを確認する。test除外pathだけの変更は共通フローの例外に従う。
5. 追跡対象のRed用testをリポジトリのGit規約どおりコミットし、worktreeがcleanであることを確認してから、`bash [skills_root]/polish/capture-scope.sh <scope名> --auto`を実行する。
6. ユーザー依頼の全要件、surveyorの確認済み事実、test_scenarios、Red、想定変更先、変更禁止カテゴリを一つの自然文briefにする。test_scenariosの採否で実装指示を削らない。想定変更先は認可リストにしない。同型実装から名前・内容を一意に決められる新規本体ファイルも要件内なら許可する。
7. 共通フローのStep 4〜8を完了する。native implementerにテスト、設定、migration、Git、設計資産を変更させない。追加production fileが必要だった場合は親が因果を確認し、実差分を全件レビューする。
8. Greenに加え、path指定可能な既存lintを実行する。利用可能なcommandがなければ発明せず、`not run`として報告する。

ユーザーが設定やmigration fileなどerrand禁止対象の変更を明示した場合は、`errand`を終了して通常実装へ移ることを一文で宣言する。明示された範囲だけを通常実装として扱う。

## 完了報告

依頼、選択済みtest_scenarios、Red、Green、native survey task、implementerの結果、実差分の採否、実行した検証と`scope-related` / `unrelated` / `uncertain` / `not run`の分類、コミットを簡潔に報告して停止する。対象外の失敗だけでタスクを未完了と決めない。
