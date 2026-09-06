---
name: errand
description: "ユーザーが$errandを明示し、設計書を作らず、既存パターンから一意に決まる小さな本体コード修正・定型ファイル追加・Prisma schema追加を、上位モデルの調査とテストシナリオ選択、Red、下位implementerの初回実装・大きい修正の再実装、上位モデルの最終レビューまで完了したいときだけ使う。新機能設計、要件判断、設定・migration・依存関係の変更には使わない。"
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: Agent
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/require-implementer.sh workflow
---

## 目的

設計書を作る価値がないほど小さく、依頼と最寄りの既存パターンから変更内容・完了条件を一意に確定できる実装を、`direct survey → scenario → red → lower-model implementer → review-reimplementation → green-final-review`で完了する。新しいテストが必要でも停止せず、[agent_name]が候補を提示し、ユーザーが選択したものだけをテストへ変換する。

開始時に[シナリオ駆動の共通実装フロー](../SCENARIO_FLOW.md)を全文読み、上位モデルの調査とテストシナリオ選択、Red、下位implementerの初回実装、上位モデルのGreenの正本として従う。

## 起動境界

ユーザーが明示的にerrandを呼んだ場合だけ使う。通常の自然言語依頼から自動起動せず、meeting / cowlick / ponytail / tddは呼ばない。

次のいずれかなら、変更せず理由を報告して停止する。新しいテストまたはテストファイルが必要なことは停止理由にしない。

- 要件、公開挙動、完了条件のいずれかを依頼と既存パターンから一意に決められない
- シナリオを作るために新しいAPI、認可境界、データ契約などの設計判断が必要になる
- migration、設定、依存関係、CI、スキル、Git管理ファイルを変更する
- Red用testのcommit後もユーザー由来のdirty fileが残る

対象ファイルが未実装、複数、または対応テストが未作成であることだけを理由に停止しない。単一の公開挙動について同じ既存パターンから各変更を一意に決められる限り、複数の本体コードと`schema.prisma`を一つのerrandで扱う。Prisma modelのフィールド、型、主キー、relationを依頼または同型実装から一意に決められない場合は停止する。migration fileの作成と`prisma migrate`・`prisma db push`・`prisma db execute`は常に禁止する。

## 実行手順

1. 依頼から公開挙動、完了条件、ASCII kebab-caseのscope名を固定する。識別子、path、番号、固有名詞を省略・翻訳・一般化しない。
2. 共通フローのStep 0で上位モデルが直接調査する。最寄りの同型実装1件の正確なpath、置き換える識別子・値、想定変更先、既存の検証commandを確認する。依頼後の挙動と実装方法を一意に決められなければ変更せず停止する。
3. 追加の完了条件として、path指定可能な既存lintを共通フローStep 7の実行対象へ含める。利用可能なcommandがなければ発明せず、`not run`として報告する。
4. ユーザー依頼を要求根拠として共通フローのStep 1〜8を完了する。定型追加も含め、同型実装から名前・内容を一意に決められる新規本体ファイルだけを実装範囲へ含める。

ユーザーが設定やmigration fileなどerrand禁止対象の変更を明示した場合は、`errand`を終了して通常実装へ移ることを一文で宣言する。明示された範囲だけを通常実装として扱う。

## 完了報告

依頼、選択済みtest_scenarios、Red、Green、[agent_name]が調査した範囲、implementerの結果、実差分の採否、大小判定と修正主体、最終レビュー、実行した検証と`scope-related` / `unrelated` / `uncertain` / `not run`の分類、コミットを簡潔に報告して停止する。対象外の失敗だけでタスクを未完了と決めない。
