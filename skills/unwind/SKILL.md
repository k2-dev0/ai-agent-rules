---
name: unwind
description: "polishから呼び、変更済み本体コードの3段以上の制御フローネストを検出・縮退する。"
allowed-tools: Read, Grep, Glob, Edit, Write, Bash, Agent
---

## 対象・判定

polish内部でのみ実行する。親から渡された機能名と、追跡・commit済みでcleanな本体コードの相対pathを使う。verifiedは実変更path、directは明示path。`unwind`自身では差分を再探索・再検証しない。

test・設定・文書・Prisma schema・生成物・vendor・依存物・未変更file・削除済みfileは対象外。入力不足は親へ返し、空一覧なら検出を省略する。

判定は[検出契約](NESTING_CONTRACT.md)に従い、3段以上を意味を保って2段以下へ減らす。

## 手順

検出候補の抽出だけを下位モデルへ渡す。機能の目的、要件、設計、変更範囲の調査は依頼しない。候補の採否、修正・却下判断、検証はすべて上位モデルが行う。

起動・待機は[子・待機の規則](../SUBAGENT_RULES.md)に従う。

1. 親スキルが渡した本体コードのpathだけを、専用`nesting-reviewer`へ渡す。briefは機能名・repository絶対path・HEAD・対象path。Codexは`agent_type: "nesting-reviewer"`と`fork_context: false`または`fork_turns: "none"`、Claudeは`subagent_type: "nesting-reviewer"`。model・effortは専用定義を使い、上書き・resume・backgroundは指定しない。利用不能なら親へ失敗を返す。
2. 返却されたchild ID／task pathで完了を待ち、全対象pathの検出完了と候補のfile・行・最大深さ・到達条件を確認する。待機先なし・未読pathありは失敗。検出中は対象を変更せず、HEAD・対象内容が変わった結果は破棄して新規起動する。失敗・中断・対象外変更は品質ゲート失敗。候補なしなら「3段階以上の制御フローネストなし」と返す。
3. guard clause（return/continue/break/throw）→ 条件反転 → 排他的分岐のswitch・状態表・dispatch map化 → 不要な反復の除外、の順で検討する。
4. 修正時は[レビューフロー](../REVIEW_FLOW.md)を全文読み、大小判定・修正担当・検証に従う。対象test・型検査・lintと、親の`polish`が実行した同じpackageのbuildを再実行する。build未実行は理由を引き継ぎ、新しいbuild commandを発明しない。
5. 修正をcommit後、新HEADと新しいサブエージェントで再検出する。安全に縮退できない候補は理由・却下案を親へ返す。

## 禁止

- 深いブロックを新しい関数・メソッド・helperへ切り出して直後に呼ぶ
- IIFE、callback、lambda、local functionへ押し込む
- helperの呼び出し先へ同じネストを移す

新しい関数境界には独立した業務責務・公開契約が必要。ネストを隠す目的では作らない。

## 返却

child ID／task path・検出結果、候補の最大深さ・到達条件、大小判定・修正主体、縮退結果／残す理由、test・型検査・lint・buildの結果を返す。
