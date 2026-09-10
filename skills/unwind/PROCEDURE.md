## 対象・判定

機能名と、追跡・commit済みでcleanな本体コードの相対pathを受け取る。明示呼び出しはdirectとし、機能名・対象pathの不足は確認する。既存の検証結果・commandを引き継ぎ、未実行の検証は`not run`とする。親からの呼び出しでは渡された入力を使う。verifiedは実変更path、directは明示path。`unwind`自身では差分を再探索・再検証しない。

test・設定・文書・Prisma schema・生成物・vendor・依存物・未変更file・削除済みfileは対象外。入力不足は呼出元へ返し、空一覧なら検出を省略する。

検出契約は子が読む。メインは候補の採否に必要な場合だけ[検出契約](NESTING_CONTRACT.md)の該当箇所を読み、3段以上を意味を保って2段以下へ減らす。

## 手順

独立レビューとして検出候補の抽出だけを`nesting-reviewer`へ渡す。機能の目的、要件、設計、変更範囲の調査は依頼しない。候補の採否、修正・却下判断、検証はメインが行い、[メインモデル選択](../MODEL_SELECTION.md)に従う。

子の起動直前に[子・待機の規則](../SUBAGENT_RULES.md)を読む。

1. 入力された本体コードのpathだけを、専用`nesting-reviewer`へ渡す
   - briefは機能名・repository絶対path・HEAD・対象path
   - Codexは`agent_type: "nesting-reviewer"`と`fork_context: false`または`fork_turns: "none"`、Claudeは`subagent_type: "nesting-reviewer"`
   - model・effortは専用定義を使う
   - 利用不能なら呼出元へ失敗を返す
2. 返却されたchild ID／task pathで完了を待ち、全対象pathの検出完了と候補のfile・行・最大深さ・到達条件を確認する
   - 待機先なし・未読pathありは失敗
   - 検出中は対象を変更せず、HEAD・対象内容が変わった結果は破棄して新規起動する
   - 失敗・中断・対象外変更は品質ゲート失敗
   - 候補なしなら「3段階以上の制御フローネストなし」と返す
3. guard clause（return/continue/break/throw）→ 条件反転 → 排他的分岐のswitch・状態表・dispatch map化 → 不要な反復の除外、の順で検討する
4. 修正時だけ[修正ループ](../FIX_FLOW.md#修正ループ)を読み、メインが修正・検証する
   - 対象test・型検査・lintと、入力の検証結果にある同じpackageのbuildを再実行する
   - build未実行は理由を引き継ぎ、新しいbuild commandを発明しない
5. 修正をcommit後、新HEADと新しいサブエージェントで再検出する
   - 安全に縮退できない候補は理由・却下案を呼出元へ返す

## 禁止

- 深いブロックを新しい関数・メソッド・helperへ切り出して直後に呼ぶ
- IIFE、callback、lambda、local functionへ押し込む
- helperの呼び出し先へ同じネストを移す

新しい関数境界には独立した業務責務・公開契約が必要。ネストを隠す目的では作らない。

## 返却

child ID／task path・検出結果、候補の最大深さ・到達条件、縮退結果／残す理由、test・型検査・lint・buildの結果を返す。
