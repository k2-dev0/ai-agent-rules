---
name: tdd
description: "スキル未指定の実装・修正依頼、または明示的な$tddで使う。通常はユーザー依頼、--from-doc時だけ設計書を基に実装する。明示された別スキルと進行中の工程を優先し、質問・説明・読み取りだけの調査では起動しない。"
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent
---

## 入力・停止条件

| 起動 | 要求根拠・scope名 |
|---|---|
| 通常（引数なし・依頼文あり・自動選択） | ユーザー依頼と確認済み事実。scope名はASCII kebab-caseで決める。`prompt/`は読まない |
| `$tdd --from-doc` | `.[agent_name]/prompt/.prompt.md`の先頭`- [ ] branch-<機能名>-prompt.md`が指す設計書と確認済み事実。機能名をscope名とする |

`--from-doc`では対象1枚だけを1 branch・1 PRとして扱い、他の設計書や次の項目へ進まない。index・参照先なしは変更せず停止し、未完了項目なしなら完了済みと報告する。通常起動で実装依頼が不明なら確認する。

依頼の識別子、path、番号、固有名詞を省略・翻訳・一般化しない。未実装、複数path、対応test未作成だけでは停止しない。承認範囲外のDB・依存・公開API変更、新しい設計判断が必要な場合は実装を止め、未解決事項を報告する。

調査・実装・修正・検証はメインが行う。参照先は各工程の読込条件を満たした時点で読む。

## 0. [agent_name]が直接調査する

要求の識別子・path・番号・固有名詞から対象、最寄りの同型実装、schema・test・route、検証commandを確認する。調査開始時に[共通基準](../IMPLEMENTATION_RULES.md)と該当規約を読む。

`path:line`、想定変更先、関連test・command、未確認事項を保持する。事実と推測を分け、必須事実が不足する場合は[agent_name]が追加調査する。

## 1. テストシナリオ候補をまとめて提示する

要求と確認済み事実から、正常・境界値・異常・副作用・回帰の候補を「前提・操作・期待結果」で日本語で提示する。どの候補を採用・不採用・修正するかはユーザーが決める。選択が確定するまでファイルを変更しない。

「採用するシナリオ、外すシナリオ、修正点を指定してください。」と尋ねる。全件採用を既定または要求する言い方をしない。選択結果を`test_scenarios`とする。

シナリオの不採用・削除・統合を、実装要件を省略する根拠にしてはならない。実装範囲の変更には要求根拠の明示的な変更が必要。

| 変更 | 再選択 |
|---|---|
| シナリオ追加・削除・統合、前提・期待結果・対象責務・公開挙動の変更 | 必要 |
| 選択済みシナリオを保つimport・型・構文・テスト構造の修正 | 不要 |

新しいテストが必要であることだけを理由に停止しない。公開挙動を一意に決められない場合は設計確認へ戻す。

文書・設定・書式だけの変更は必要な検証だけを行う。次のtest除外pathだけの変更では対応test/specの作成・実行とRed / Greenを要求せず、候補提示も省略する。

- `schema.prisma`
- basenameが`constants.ts`または`constants.js`
- `constants/`配下

その他の本体コードの公開挙動も変える場合は、その挙動だけを通常どおりシナリオ、Red、Greenの対象にする。

## 2. テストを書く

テストを含む最初の編集前に、選択済みシナリオを含めて実装方針を確定し、メインモデル選択基準の独立評価と必要な切替を済ませる。テスト工程を省略する場合も、最初の編集前に同じ条件を満たす。

選択済みシナリオを実装し、既存assertionを弱めない。配置は既存規約に合わせ、追跡対象はGit規約どおりコミットする。ignore規則に一致するtestはローカルで使う。追跡・ignoreのどちらにも該当しない未追跡testは停止対象。

- 1 test 1 assertionを原則とし、describeは2階層まで。
- 結合テストを優先し、API・DB処理はPrisma mockでなくテストDBを使う。
- 外部API関数はmockで呼び出し条件・異常系、複雑な分岐はunit testで境界値・全分岐を検証する。その他のunit testは回帰防止・原因分離が必要な場合だけ追加する。
- `.jsx` / `.tsx` component・React hook専用の隣接unit testは新設せず、既存integration / E2E境界で検証する。
- 非公開関数は公開API経由で検証する。

ユーザーがテスト作成済みと明示した場合は、候補提示・作成を省略できる。対象test、要求を検出できること、実装前のRedは確認する。

## 3. Redと実装前baseline

既存test scriptで対象testを実行し、実装不足・期待値との差による失敗を確認する。runner直起動・`npx vitest`・`npx jest`は禁止。

| 結果 | 対応 |
|---|---|
| syntax・import・型の失敗 | シナリオを変えず修正 |
| 未確認の事実が必要 | Step 0へ戻る |
| 最初からGreen | 要求を検出できるtestか確認 |
| シナリオ変更が必要 | Step 1へ戻る |

追跡対象testをコミットし、worktreeがcleanであることを確認する。ユーザー由来のdirty fileが残れば実装を停止する。ignored testはdirtyに含めない。test工程を省略した場合も、実装直前に[polishの実装前baseline](../polish/BASELINE.md)をscope名で記録する。

## 4. 実装する

確定済み要件・不変条件・変更範囲・検証方法に従って実装する。方針変更が必要なら、その変更に依存する編集前にメインモデル選択基準の再評価条件を適用する。

想定変更先は探索の起点とし、要求に直接必要なproduction code・schema・型・callerを変更する。検証シナリオで実装要件を狭めず、テスト環境検出・値のハードコード・assertion攻略は禁止する。選択済みシナリオのテスト修正はStep 2、シナリオ変更はStep 1に従う。

## 5. 相談・無変更・中断

| 結果 | 対応 |
|---|---|
| 追加調査で一意に解決できる | Step 0で追加調査し、既存の変更を保持して続行 |
| 非ブロッキングな改善案 | 記録して続行 |
| 新しい設計判断 | 実装を止め、未解決事項を報告 |
| 説明・分類のみ、または実差分0 | 要件が既存実装で満たされている根拠を確認し、不足があれば実装を続行 |
| 中断後の再開 | 実差分と検証結果から未完了作業を特定し、完了済み操作を繰り返さない |

## 6. Green・静的検証

メインが次を順に実行する。子の自己申告で代用せず、無関係なpackageのtestやproject全体のtestを追加しない。

| 条件 | 実行 |
|---|---|
| 選択済みシナリオのtest | 全件 |
| 直接の回帰検証と確認した既存test | 全件 |
| TypeScript / JavaScript変更 | 所属packageのtypecheck。なければ`tsc -p <tsconfig> --noEmit` |
| `schema.prisma`変更 | 所属packageのPrisma `format`、`validate`、`generate` |
| 対象path指定可能な既存lintあり | 変更pathだけ |
| 要求根拠の追加完了条件 | 指定command |

commandは`target-test`、`direct-regression`、`typecheck`、`schema`、`lint`等に分類し、対象pathと対応を示す。commandがなければ発明せず`not run`と報告する。検証が失敗した場合だけ[修正ループ](../FIX_FLOW.md#修正ループ)を読み、修正・再検証する。

## 7. 失敗の分類・完了処理

診断がある場合だけ[診断のscope帰属](../FIX_FLOW.md#診断のscope帰属)を読み、分類する。完了条件、Greenまたはtest除外、追跡対象のcommitを確認する。対象外の失敗だけで未完了と決めない。

`--from-doc`の場合だけ次を実行する。

```bash
bash [skills_root]/polish/capture-scope.sh list-changed <機能名>
```

この出力にある実変更pathだけをまとめて[polishの手順](../polish/PROCEDURE.md)へ渡し、verifiedで実行する。ファイルごとには呼ばない。

両モードとも、検証・commit（`--from-doc`ではpolishも）完了後に[独立レビュー](../INDEPENDENT_REVIEW.md)を読み、実行する。

要求根拠、選択済みシナリオ、Red・Green／test除外、調査結果、実差分、残作業・独立レビュー結果、検証の`scope-related`／`unrelated`／`uncertain`／`not run`、commitを簡潔に報告する。通常起動はここで終了する。

`--from-doc`ではpolish・index残件数も報告し、完了マークを付けるか明示的に確認する。ユーザーが付けると回答した場合だけ単独実行する。

```bash
bash [skills_root]/tdd/mark-prompt-done.sh <機能名>
```
