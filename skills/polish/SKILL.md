---
name: polish
description: 実装完了後に変更済みコードへフォーマッタ・リンター・型検査と変更行限定の共通規約を適用し、DeepSeek が検出した三段階以上の制御フローネストだけを unwind で見直す。
allowed-tools: Read, Grep, Glob, Edit, Write, Bash, Skill(unwind)
disable-model-invocation: true
---

## 目的

呼び出し元が開始時に固定した本体コードだけを整形・静的検査し、変更行規約と`unwind`を通す。

## 入力と対象

機能名と変更済み**追跡済み本体コードの相対path**全件を一括入力にする。ファイルごとに分割起動しない。不足時は差分から補完せず失敗にする。対象は`tdd`が変更前に`capture-scope.sh`で固定したpathと完全一致させる。各pathを、直近の`package.json`、`tsconfig.json`、formatter / lint設定、Prisma schemaが属するpackageへ対応付ける。無関係なdirty fileとproject全体への`--write` / `--fix`は対象外にする。

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

同じpathを複数formatterまたはlinter設定が支配し、既存scriptでも一意にならない場合は勝手に選ばず失敗にする。必要なtoolが未導入ならinstallせず、実行できなかった検査を返す。

## 制御フローネストの品質ゲート

実行表が成功した後に`unwind`を必ず呼ぶ。返却された候補だけを読み、早期return等で構造的に減らせるか判断する。関数抽出で深さを隠さない。

`unwind` がコードを変更した場合は、対象テスト・型検査・lintを再実行し、通常の変更と同じ単位でコミットした後、DeepSeek へ再検出を委任する。縮退できない候補がある場合も、下位モデルの task-id・結果パス・理由と却下案を最終報告用に返すまで完了扱いにしない。

## 変更行だけの共通規約

実行表、`unwind`、必要な修正と再検証を終え、対象変更をコミットしてから次を実行する。pathは入力と同じ順序で全件渡す。

```bash
bash [skills_root]/polish/check-changed-rules.sh <機能名> -- <相対path>...
```

固定した開始commitから対象pathへ追加・置換された現在行だけを、既存ESLintのAST診断で検査する。削除行と未変更行は対象外で、この検査はファイルを変更しない。

- TypeScript / JavaScriptの静的import、dynamic import、`require`で`../../`以上を参照した変更行を拒否する
- `no-magic-numbers`診断のうち変更行に一致するものだけを拒否する
- ESLintが未導入、実行不能、構文解析失敗なら未検査として失敗する

違反は上位モデルが変更行だけで修正し、テスト・型検査・lint・commit・同じcheckを再実行する。未変更部分の既存違反を修正対象へ広げない。

## 反復条件

修正原因と修正主体により再検証範囲を決める。

| 原因 | 修正後の処理 |
|---|---|
| formatterがformat差分を自動修正 | 再起動せず後続のlintへ進む |
| linterが自動修正 | formatterとlintを再確認して後続へ進む |
| 型error、構文error、非自動修正のlint error、Prisma整合性error、test失敗 | 上位モデルが修正し、必要なtestとcommit後にpolishを先頭から再実行 |
| `unwind`または変更行規約による修正 | 上位モデルが修正し、必要なtestとcommit後にpolishを先頭から再実行 |
| tool未導入、設定競合、実行不能 | 再実行で隠さず停止して未実行項目を返す |

決定的tool自身の修正は、それ以前の結果を無効化する範囲だけ再確認する。上位モデルがコードを判断して修正した場合は全品質ゲートを再実行する。最終の一周がすべて成功した時だけ完了し、ファイル単位の起動へ分割しない。

## tdd from-prompt への完了通知

`tdd`の`from-prompt` modeから機能名と本体コードの相対path一覧を渡されて実行した場合は、すべての品質ゲート（変更行規約とDeepSeekによる再検出を含む）を終え、追跡対象の変更をコミットした後に次を実行する。設計書path modeでは記録しない。

```bash
bash [skills_root]/polish/quality-gate.sh record <機能名>
```

この receipt は現在の HEAD と追跡対象の clean 状態を結び付ける。失敗した場合は完了を報告せず、変更の検証とコミットをやり直す。
