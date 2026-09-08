---
name: errand
description: "明示的な$errandで、既存パターンから一意に決まる小修正・定型追加・Prisma schema変更を設計書なしで実装する。"
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent
disable-model-invocation: true
---

## 対象・停止条件

ユーザーが明示的にerrandを呼んだ場合だけ使う。meeting / cowlick / ponytail / tddは呼ばない。開始時に[共通実装フロー](../SCENARIO_FLOW.md)を読む。参照先は各工程の読込条件を満たした時点で読む。

| 条件 | 対応 |
|---|---|
| 要件・公開挙動・完了条件・実装方法を依頼と既存パターンから一意に決められる | 実行 |
| 未実装、複数path、対応test未作成 | それだけでは停止しない。単一の公開挙動に必要な変更を扱う |
| 新しいAPI・認可境界・data契約などの設計判断が必要 | 変更せず停止 |
| migration・設定・依存・CI・skill・Git管理fileの変更 | errandの対象外 |

Prismaのfield・型・主キー・relationを一意に決められれば`schema.prisma`を変更できる。migration fileの作成は対象外。

禁止対象の変更をユーザーが明示した場合は、errand終了と通常実装への移行を一文で伝え、指定範囲を扱う。

## 手順

1. 依頼から公開挙動・完了条件・ASCII kebab-caseのscope名を決める。識別子、path、番号、固有名詞を省略・翻訳・一般化しない。
2. 共通フローStep 0でメインが直接調査する。最寄りの同型実装1件のpath、置換する識別子・値、想定変更先、検証commandを確認する。
3. 要求根拠をユーザー依頼として共通フローのStep 1〜7を実行する。同型実装から名前・内容を一意に決められる新規本体ファイルも含める。
4. 共通フローStep 6に対象path指定可能な既存lintを加える。commandがなければ`not run`とする。
5. 検証・commit後に[独立レビュー](../INDEPENDENT_REVIEW.md)を読み、実行する。

## 報告

依頼、選択済みシナリオ、Red・Green、調査結果、残作業・独立レビュー結果、検証の`scope-related`／`unrelated`／`uncertain`／`not run`、commitを報告して停止する。対象外の失敗だけで未完了と決めない。
