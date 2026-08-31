---
name: polish
description: 実装完了後にbaselineからの実変更コードへフォーマッタ・リンター・型検査・buildを適用し、path整合性を検証して、workerが検出した三段階以上の制御フローネストだけをunwindで見直す。
allowed-tools: Read, Grep, Glob, Edit, Write, Bash, Skill(unwind)
disable-model-invocation: true
---

## 目的

呼び出し元が実装直前に記録したbaselineから、実際に変更された本体コードだけを整形・静的検査・buildし、診断をscopeへ帰属させてからpath検査と`unwind`を通す。

## 入力と対象

機能名を受け取り、最初に次を実行する。

```bash
bash [skills_root]/polish/capture-scope.sh list-changed <機能名>
```

`--auto`で記録したbaselineでは、基準commitから現在HEADまで実際に差分があり、現在も存在する追跡済みfileがGitの順序で返る。従来の個別path receiptでは、候補のうち実際に変更されたfileだけがreceipt順で返る。この出力と完全一致する相対path全件を一括入力とし、directory、glob、`git diff`で独自に広げたpathを使わない。commit済み削除はformatter・lint・`unwind`・path検査の対象外にする。出力が空なら実行表と`unwind`を省略し、path検査へ進む。

各実変更pathを、直近の`package.json`、`tsconfig.json`、formatter / lint設定、Prisma schemaが属するpackageへ対応付ける。formatter・lint・`unwind`へは実変更pathだけを渡し、無関係なdirty fileとproject全体への`--write` / `--fix`は対象外にする。typecheck・build・Prisma検証はファイル単位で安全に分割できないため、実変更pathが属するpackageまたはschemaだけを起点に既存単位で実行する。ただしpackage単位の失敗全体を今回の失敗とは扱わない。

## 実行表

packageごとに上から実行する。既存scriptを第一選択にし、scriptがない場合だけ同じpackageの`node_modules/.bin`を使う。`npx`とinstallは禁止する。

| 条件 | 実行 | 範囲 |
|---|---|---|
| `format` scriptがpathを受ける | `yarn format -- <paths>` | 対象pathだけ |
| 上記なし、Prettier設定あり | `prettier --write <paths>` | 設定が支配する対象pathだけ |
| 上記なし、Biome設定あり | `biome format --write <paths>` | 同上 |
| `lint` scriptがpathを受ける | `yarn lint -- <paths>` | 対象pathだけ |
| 上記なし、ESLint設定あり | `eslint --fix <paths>` | 同上 |
| 上記なし、Biome設定あり | `biome lint --apply <paths>` | 同上 |
| TypeScript / JavaScriptを含み`typecheck` scriptあり | packageで`yarn typecheck` | package単位で1回 |
| 上記scriptなし、`tsconfig.json`あり | `tsc -p <tsconfig> --noEmit` | package単位で1回 |
| `schema.prisma`を含む | Prismaの`format`、`validate`、`generate` | schemaが属するpackage |
| 実変更pathが属するpackageに`build` scriptあり | packageで`yarn build` | package単位で1回 |

同じpathを複数formatterまたはlinter設定が支配し、既存scriptでも一意にならない場合は勝手に選ばず`not run`として返す。`build` scriptがないpackageのbuild commandは推測・発明しない。必要なtoolが未導入ならinstallせず、実行できなかった検査を`not run`として返す。

polish自体はtest commandを追加実行しない。`schema.prisma`、basenameが`constants.ts`または`constants.js`のfile、`constants/`配下のfileだけの変更では、それらを理由に対応testを探索・実行しない。

## 診断のscope帰属

各commandの終了codeだけでpolishの成否を決めず、diagnosticごとに次へ分類する。

- 実変更path自体、または変更した公開型・export・契約との直接の因果関係を確認できる失敗は`scope-related`
- 無関係な未変更file、今回作成・変更していないignored / untracked test、checkout前のbranchの残留testが消えた実装を参照する失敗は`unrelated`
- 因果関係を確定できない失敗は`uncertain`

`scope-related`だけを修正と再検証の対象にする。承認範囲内の修正を尽くしても残る場合は`scope fail`として返す。`unrelated`はファイルを修正・削除せず、command、diagnostic、対象外と判断した根拠を返して後続へ進む。`uncertain`は推測で成功または失敗に倒さず返す。どの分類もユーザーの完了マーク判断を代行しない。

## 制御フローネストの品質ゲート

実行表に`scope-related`な失敗が無く、その他のdiagnosticを分類した後に、実変更pathだけを渡して`unwind`を必ず呼ぶ。開始scopeの未変更pathを混ぜない。返却された候補だけを読み、早期return等で構造的に減らせるか判断する。関数抽出で深さを隠さない。

`unwind` がコードを変更した場合は、対象テスト・型検査・lint・親スキルが実行した同じpackageのbuildを再実行し、通常の変更と同じ単位でコミットした後、外部ワーカーへ再検出を委任する。縮退できない候補がある場合も、下位モデルの task-id・結果パス・理由と却下案を最終報告用に返してから後続へ進む。

## scope path検査

実行表、`unwind`、必要な修正と再検証を終え、対象変更をコミットしてから、polish開始時に得た実変更pathを同じ順序で全件渡す。`list-changed`をもう一度実行しない。入力が空なら`--`の後へpathを付けない。

```bash
bash [skills_root]/polish/quality-gate.sh <機能名> -- <実変更path>...
```

開始receiptのrepository・基準commit・modeを読み、現在の入力pathを「基準commitから実際に変更され、現在存在するfile」の一覧と順序込みで完全一致させる。個別path receiptでは候補一覧も照合する。入力された実変更pathだけが追跡済みかつcleanであることを検査する。完了receiptの記録や後続での再検証は行わない。ソース内容は解析せず、独自のESLint rule、`no-magic-numbers`、import規則を追加しない。コード規約は実行表の既存lint設定へ任せる。

## 反復条件

修正原因と修正主体により再検証範囲を決める。

| 原因 | 修正後の処理 |
|---|---|
| formatterがformat差分を自動修正 | 再起動せず後続のlintへ進む |
| linterが自動修正 | formatterとlintを再確認して後続へ進む |
| `scope-related`な型error、構文error、非自動修正のlint error、Prisma整合性error、build error | 上位モデルが修正し、必要な検証とcommit後にpolishを先頭から再実行 |
| `unrelated`または`uncertain`な失敗 | 対象外fileを変更せず分類根拠を返し、後続のscope path検査へ進む |
| `unwind`による修正 | 上位モデルが修正し、必要なtestとcommit後にpolishを先頭から再実行 |
| tool未導入、設定競合、実行不能 | 再実行で隠さず`not run`と理由を返し、後続のscope path検査へ進む |

決定的tool自身の修正は、それ以前の結果を無効化する範囲だけ再確認する。上位モデルがコードを判断して修正した場合は全品質ゲートを再実行する。最終報告では実行済みcommandを`scope pass`、`scope fail`、`unrelated failure`、`uncertain`、`not run`へ分類し、ファイル単位の起動へ分割しない。
