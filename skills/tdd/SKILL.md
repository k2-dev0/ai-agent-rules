---
name: tdd
description: "runtime挙動を実装・修正する依頼、または明示的な$tddで使う。明示された別skillと進行中の工程を優先する。質問・調査・review、文書・設定・書式だけの変更、挙動を変えない整理では起動しない。--from-doc時だけ設計書を使う。"
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent
---

# TDD

通常起動はユーザー依頼と確認済み事実を根拠とし、`prompt/`を読まない。scope名はASCII kebab-caseで決める。`$tdd --from-doc`はユーザーが明示した場合だけ使い、通常起動から切り替えない。明示された場合は最初に[設計書モード](FROM_DOC.md)を読む。

調査・実装・修正・検証はメインが行う。依頼の識別子・path・番号・固有名詞は変えない。承認範囲外のDB・依存・公開API変更、または新しい設計判断が必要なら編集を止めて報告する。

## 調査

要求の識別子・path・番号・固有名詞から対象、最寄りの同型実装、schema・test・route、検証commandを確認する。`path:line`、想定変更先、関連test・command、未確認事項を保持し、必須事実が足りなければ追加調査する。

## シナリオ選択

調査後、シナリオと実装方針を決める前に[共通基準](../IMPLEMENTATION_RULES.md)と該当規約を読む。

正常・境界値・異常・副作用・回帰の候補を「前提・操作・期待結果」でまとめ、採用・不採用・修正をユーザーへ確認する。選択確定まで編集せず、全件採用を既定にしない。シナリオの不採用を実装要件の削減理由にしない。

公開挙動・前提・期待結果・対象責務を変える場合は再選択する。選択済み挙動を保つimport・型・構文・test構造の修正では再選択しない。新しいtestが必要なだけでは止めず、公開挙動が一意でなければ設計確認へ戻る。

`schema.prisma`、`constants.ts` / `constants.js`、`constants/`だけの変更では候補提示・test追加・Red / Greenを省略する。他のruntime挙動も変える場合はその挙動を通常どおり扱う。

## Red

選択済みシナリオのtestを書き、既存assertionを弱めない。既存の配置・方式に合わせて結合testを優先し、API・DB処理はPrisma mockでなくtest DBを使う。外部APIはmockで呼出条件と異常系、複雑な分岐はunit testで境界と分岐、非公開処理は公開APIから検証する。React component・hook専用の隣接unit testは新設しない。

ユーザーがtest作成済みと明示した場合は候補提示・作成を省略できるが、対象testが要求を検出し、実装前に失敗することを確認する。

既存test scriptで、対象testが実装不足または期待値との差により失敗することを確認する。syntax・import・型の失敗はシナリオを変えず先に直す。最初から成功するtestは要求を検出できるか確認し、未確認事実が必要なら調査へ、シナリオ変更が必要なら選択へ戻る。

追跡対象testをcommitし、cleanな状態で実装直前に[baseline](../polish/BASELINE.md)を記録する。ユーザー由来のdirty fileが残れば実装を止める。

## 実装・検証

確定済み要件・不変条件・変更範囲・検証方法に従い、要求に必要なproduction code・schema・型・callerだけを変更する。test環境の検出、値のhardcode、assertion攻略で要件を回避しない。方針変更が必要なら[メインモデル選択](../MODEL_SELECTION.md)の再評価条件を適用する。

選択済みtest、直接の回帰test、変更packageのtypecheck、対象pathのlint、変更schemaのPrisma `format`・`validate`・`generate`、要求された検証を実行する。typecheck scriptがなくtsconfigがあれば`tsc -p <tsconfig> --noEmit`を使う。無関係なpackage・repository全体へ広げず、commandがなければ発明せず`not run`とする。

失敗時だけ[修正手順](../FIX_FLOW.md)を読み、修正・再検証する。診断が残る場合は同文書のscope帰属で分類する。

## 完了

通常起動は検証とcommit後に専用reviewerで独立レビューし、要求、選択済みシナリオ、Red・Greenまたはtest除外、実差分、検証結果、未実行・残作業、commit、レビュー結果を簡潔に報告する。`--from-doc`は[設計書モード](FROM_DOC.md)の完了処理へ進む。
