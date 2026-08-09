---
name: polish
description: 実装完了後に変更済みコードへフォーマッタ・リンター・型検査を適用し、DeepSeek が検出した三段階以上の制御フローネストだけを unwind で構造的に見直す。
allowed-tools: Read, Grep, Glob, Edit, Write, Bash, Skill(unwind)
disable-model-invocation: true
---

## 目的

呼び出し元が渡した変更済み本体コードだけを整形・静的検査し、最後に`unwind`を実行する。

## 入力と対象

機能名と変更済み**追跡済み本体コードの相対path**を必須入力にする。不足時は差分から補完せず失敗にする。各pathを、直近の`package.json`、`tsconfig.json`、formatter / lint設定、Prisma schemaが属するpackageへ対応付ける。無関係なdirty fileとproject全体への`--write` / `--fix`は対象外にする。

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

## tdd from-prompt への完了通知

`tdd`の`from-prompt` modeから機能名と本体コードの相対path一覧を渡されて実行した場合は、すべての品質ゲート（DeepSeekによる再検出を含む）を終え、追跡対象の変更をコミットした後に次を実行する。設計書path modeでは記録しない。

```bash
bash [skills_root]/polish/quality-gate.sh record <機能名>
```

この receipt は現在の HEAD と追跡対象の clean 状態を結び付ける。失敗した場合は完了を報告せず、変更の検証とコミットをやり直す。
