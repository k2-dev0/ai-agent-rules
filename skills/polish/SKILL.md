---
name: polish
description: 実装完了後に変更済みコードへフォーマッタ・リンター・型検査を適用し、DeepSeek が検出した三段階以上の制御フローネストだけを unwind で構造的に見直す。
allowed-tools: Read, Grep, Glob, Edit, Write, Bash, Skill(unwind)
disable-model-invocation: true
---

## 目的

未ステージング・ステージング済みの変更ファイルに対して、コードの品質維持およびプロジェクトのスタイルガイドへの準拠を目的として、自動整形（Format）と静的解析（Lint）を実行する。呼び出し元にかかわらず、整形・lint・型検査の後に `unwind` を必ず実行する。

## ガイドライン

### 実行方法（共通）

1. `package.json` の scripts に該当タスク（`format` / `lint` / `typecheck` 等）があり、対象ファイルを渡せる場合は **script 経由**（`yarn <script> -- <対象ファイル...>`）を最優先で使うこと
2. script が無い場合のみ、下記の `node_modules/.bin/<tool>` を直接実行すること
3. **`npx` での起動は禁止**（未導入だと registry へ取りに行くため hook が deny する。`tdd-pattern.md` の test script 規約と同根）
4. ツールが未導入（`node_modules/.bin` に無い）場合は install せず、ユーザーに相談すること（install 系も deny される）
5. 呼び出し元が対象ファイルを指定した場合はその本体コードだけを対象にする。指定が無い場合も、無関係な未コミット変更やプロジェクト全体への一括 `--write` / `--fix` は実行しない

### コード整形

プロジェクトの構成を確認し、以下のいずれかの設定ファイルに基づいて整形を実行すること。

- **Prettier**: `.prettierrc` (または関連設定ファイル) を検知した場合
  - 対象ファイルを明示して `node_modules/.bin/prettier --write <対象ファイル...>` を実行する。
- **Biome**: `biome.json` を検知した場合
  - 対象ファイルを明示して `node_modules/.bin/biome format --write <対象ファイル...>` を実行する。

### 静的解析・修正

プロジェクトの構成を確認し、以下のいずれかの設定ファイルに基づいて修正を実行すること。

- **ESLint**: `.eslintrc.js` または `.eslintrc.json` を検知した場合
  - 対象ファイルを明示して `node_modules/.bin/eslint --fix <対象ファイル...>` を実行する。
- **Biome**: `biome.json` を検知した場合
  - 対象ファイルを明示して `node_modules/.bin/biome lint --apply <対象ファイル...>` を実行する。
- **typecheck**: `tsconfig.json` を検知した場合
  - ESLint or Biome の設定ファイルが存在しなかった場合は、tsconfig.json が存在するディレクトリにて `node_modules/.bin/tsc --noEmit` を実行する。

### DBスキーマの整形

- **Prisma**: `prisma/schema.prisma` を対象に含む場合
  - 設定ファイルが存在するディレクトリにて `node_modules/.bin/prisma format` を実行する。

## 制御フローネストの品質ゲート

親スキルは、機能名と変更済み**追跡済み本体コードの相対パス**を `polish` へ渡す。情報が不足した場合、`polish` は上位モデルに差分探索をさせず、品質ゲートを失敗にする。

整形・lint・型検査の後に `unwind` を必ず呼ぶ。`unwind` は固定実行器を通じて DeepSeek にネスト検出だけを委任する。上位モデルはその検出結果にある箇所だけを読み、早期 return 等で構造的に減らせるかを検討する。関数抽出で深さを別の場所へ隠してはならない。

`unwind` がコードを変更した場合は、対象テスト・型検査・lintを再実行し、通常の変更と同じ単位でコミットした後、DeepSeek へ再検出を委任する。縮退できない候補がある場合も、下位モデルの task-id・結果パス・理由と却下案を最終報告用に返すまで完了扱いにしない。

## tdd from-prompt への完了通知

`tdd`の`from-prompt` modeから機能名と本体コードの相対path一覧を渡されて実行した場合は、すべての品質ゲート（DeepSeekによる再検出を含む）を終え、追跡対象の変更をコミットした後に次を実行する。設計書path modeでは記録しない。

```bash
bash [skills_root]/polish/quality-gate.sh record <機能名>
```

この receipt は現在の HEAD と追跡対象の clean 状態を結び付ける。失敗した場合は完了を報告せず、変更の検証とコミットをやり直す。

## 注意事項
- コード整形と静的解析の対象は、`git status` で確認できる未ステージング・ステージング済みのファイルに限定すること。
