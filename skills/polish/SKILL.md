---
name: polish
description: 実装後の対象pathを整形・lint・型検査・build・ネスト検査する。
allowed-tools: Read, Grep, Glob, Edit, Write, Bash, Agent, Skill(unwind)
disable-model-invocation: true
---

## 実装前baseline

実装workflowではRed用testをコミットし、cleanな状態で実装直前に一度実行する。

```bash
bash [skills_root]/polish/capture-scope.sh <scope名> --auto
```

## 入力

開始時にモードを選び、途中で変更しない。

| モード | 対象・保証 |
|---|---|
| **verified** | 実装前receiptのある変更。実変更pathの完全性を検査する。receipt欠落は停止し、directへ降格しない |
| **direct** | 通常の直接修正で渡された相対path全件。完全性は`scope-unverified`。明示pathなしでは実行しない |

verifiedは次を実行し、この出力と完全一致する相対path全件を一括入力にする。

```bash
bash [skills_root]/polish/capture-scope.sh list-changed <機能名>
```

`--auto`は基準commit〜HEADの差分から現存する追跡fileをGit順で返す。個別path receiptは実変更fileをreceipt順で返す。削除済みfileは除外し、空なら実行表・unwindを省略してpath検査へ進む。

directは開始前に次でpath形式・重複・存在・symlink・ignoreを検査する。未追跡fileは最終gateまでに追跡・commitする。失敗時に対象を推測し直さない。

```bash
bash [skills_root]/polish/quality-gate.sh <機能名> --direct-check -- <明示path>...
```

対象をrepository全体、directory、glob、`git diff`・`git status`から推測・拡張しない。各pathを最寄りのpackage・設定・Prisma schemaへ対応付ける。formatter・lintには対象pathだけ、typecheck・build・Prisma検証には所属package/schemaだけを渡す。

## 実行表

両モードともpackageごとに上から実行する。既存scriptを優先し、なければ同じpackageの`node_modules/.bin`を使う。`npx`・installは禁止。

| 条件 | command |
|---|---|
| path指定可能なformat script | `yarn format -- <paths>` |
| 上記なし、Prettier設定あり | `prettier --write <paths>` |
| 上記なし、Biome設定あり | `biome format --write <paths>` |
| path指定可能なlint script | `yarn lint -- <paths>` |
| 上記なし、ESLint設定あり | `eslint --fix <paths>` |
| 上記なし、Biome設定あり | 導入済みhelpで修正optionを確認し`biome lint <paths>` |
| TS/JS変更、typecheck scriptあり | packageで`yarn typecheck` |
| 上記scriptなし、tsconfigあり | `tsc -p <tsconfig> --noEmit` |
| `schema.prisma`変更 | Prismaの`format`・`validate`・`generate` |
| 所属packageに`build` scriptあり | packageで`yarn build` |

package単位の検査は各1回。設定競合で一意に選べない、tool未導入、commandなしは`not run`とし、推測・installで補わない。品質検査をPrettier / ESLintだけへ縮小しない。polish自体はtestを追加実行しない。

## 診断・修正

[診断のscope帰属](../REVIEW_FLOW.md#診断のscope帰属)で分類する。コード修正が必要なら同文書を全文読み、モデルの再判定・修正・最終レビューに従う。

| 原因 | 修正後 |
|---|---|
| formatterがformat差分を自動修正 | lintへ進む |
| linterが自動修正 | formatter・lintを再確認して続行 |
| `scope-related`な型・構文・lint・Prisma・build error | `REVIEW_FLOW.md`に従って修正・必要な検証・commit後、同じ対象pathでpolishを再実行 |
| `unrelated`・`uncertain` | 対象外fileを変更せず分類を報告して続行 |
| `unwind`の修正 | メインが修正・検証・commit後、同じ対象pathでpolishを再実行 |
| tool未導入・設定競合・実行不能 | `not run`を報告して続行 |

コードの判断を伴う修正後は、全品質ゲートを再実行する。

## ネスト検査

`scope-related`失敗の解消と他の診断の分類後、確定済みの対象pathから本体コードだけを選び、`unwind`を必ず呼ぶ。test・設定・文書・Prisma schema・生成物・vendor・依存物は除外し、本体コードなしなら検出も省略する。対象を再探索しない。

返却された候補だけを確認し、関数抽出で深さを隠さない。修正後は対象test・型検査・lint・同じpackageのbuildを再実行する。縮退不能は理由・却下案・child ID／task path・検出結果を報告する。

## scope path検査

修正・検証・commit後、開始時の全対象pathを同じ順序で一度だけ渡す。ネスト検査の除外fileも含め、`list-changed`をもう一度実行しない。選んだモードのコマンドだけを単独実行する。

```bash
# verified（対象なしの場合も -- を付ける）
bash [skills_root]/polish/quality-gate.sh <機能名> -- <実変更path>...
# direct（空入力不可）
bash [skills_root]/polish/quality-gate.sh <機能名> --direct -- <明示path>...
```

verifiedはreceiptのrepository・基準commit・modeと照合し、現存する実変更pathの順序込み完全一致、全件のtracked・cleanを検査する。個別path receiptは候補一覧も照合する。directはpathの形式・重複・存在・symlink・ignore・tracked・cleanを検査するが、完全性は証明しない。

完了receiptの記録や後続での再検証は行わない。独自のESLint rule、`no-magic-numbers`、import規則を追加しない。

モード・対象pathと、commandごとの`scope pass`／`scope fail`／`unrelated failure`／`uncertain`／`not run`を返す。directは別に`scope-unverified`を示す。pathごとにpolishを分割しない。
