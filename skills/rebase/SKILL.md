---
name: rebase
description: "1 ファイル = 1 コミットで積んだコミット契約準拠の未 push 履歴を、機能単位へ自動で squash する。分類は LLM・履歴操作は決定的スクリプト（temp worktree リプレイ → 二重検証 → swap）に閉じ込め、追加承認を求めない。"
allowed-tools: Read, Grep, Glob, Bash
disable-model-invocation: true
---

## 目的

`commit-subject.sh` が検証する 1 ファイル = 1 コミット運用で積み上がった細かいコミットを、
レビューに出せる機能単位の履歴へ組み替える。**履歴書き換えの唯一の公認経路**であり、
生の rebase / filter-branch / force push は deny-history.sh が deny する。

設計思想（verify-then-swap）: 「どうまとめるか」という曖昧な判断は LLM が担い、
履歴操作はレビュー済みの `rebase.sh` に閉じ込める。スクリプトは temp worktree で
リプレイを完走させ、「plan が対象範囲を exactly-once で消費」「squash 後の tree が元 HEAD と
同一（diff 空）」の二重検証に合格して初めて本体ブランチを 1 回だけ動かす。
**検証前に本体ブランチと作業ツリーには一切触れない**ため、失敗時は temp が消えるだけで
本体は無傷 — 復元という工程そのものが存在しない。

明示的な `$rebase` 呼び出しを、未push履歴を整理する実行許可として扱う。`--check` と決定的スクリプトによる実行に追加承認を求めない。前提検査・group検証・二重検証の失敗時は履歴を動かさず、理由を報告して停止する。

## 実行フロー

### Step 0: 前提検査（スクリプト）

```
bash [skills_root]/rebase/rebase.sh --check [--base <ref>]
```

- clean tree / merge コミットなし / **範囲の全コミットが全リモート ref から不可視** /
  `commit-subject.sh` の subject 契約に一致しないコミットは境界（それより古い側は対象外）— 判定はすべてスクリプトが機械的に行う
- upstream が無いリポジトリでは `--base` が必須。推測で起点を選ばず、その理由を報告して停止する
- `NOTHING-TO-DO` が出たら正直にそう報告して終了する。無理にやることを探さない

### Step 1: 分類（read-only）

`--check` が出力する「コミット + 変更ファイル」一覧（古い順）から機能単位を作る。

| 変更 | grouping |
|---|---|
| apiとvalidation schema | 同一単位 |
| component | 1 componentで1単位 |
| migration fileとschema変更 | 同一単位 |
| helper関数・定数・変数への置き換え | 置き換え先の変更と同一単位 |
| test file（`*.test.*`） | 対象実装と同一単位 |
| linter / prettier対応commit | そのfileが属するgroup。適用順はscriptが元履歴順へ戻すため、特別扱いしない |
| messageと変更fileから判断できないcommit | 独立groupとして残す |

**静的交差検査**: 同一ファイルを触る 2 つのグループが元履歴で交差している場合、リプレイが
コンフリクトする可能性がある。planへその旨を含め、必要なら実行前に併合する。

### Step 2: 実行（スクリプト）

`--check` が出力した短縮 SHA をカンマ区切りで `--group` に直接渡す。subject は同じ出力の
`SUBJECT_FORMAT` に従う。scratch fileの作成、`git rev-parse` によるfull SHA化、
`commit-subject.sh --format` の再実行は不要。

```
bash [skills_root]/rebase/rebase.sh [--base <ref>] \
  --group '<subject 1>' '<sha1>,<sha2>' \
  --group '<subject 2>' '<sha3>'
```

- `--group` の並び = squash 後のコミット順。グループ内の commits の並びは無視される
  （スクリプトが元履歴順に再ソートする）
- スクリプトは実行前に group を検証する（対象範囲の exactly-once 消費 / hook と共有する subject 契約 /
  AI 署名不在）。エージェントは git コマンドで履歴に触らない — 触ろうとしても hook が deny する
- **コンフリクトで死んだら**: 本体は無傷。交差していたグループを併合するか、並べ替えを諦めて
  「元履歴で連続している run だけを squash する」縮退 group に組み直して再実行する
- **空グループで死んだら**: revert とその対象が同一グループで相殺されている。group を組み直す

### Step 3: 報告

squash 後の履歴・元 HEAD の sha・検証結果（tree 一致 / exactly-once）を報告する。

- **push はしない**。squash 後の履歴を最終確認して push するのは人間の仕事
- backup ブランチは残らない。swap の間だけ張る一時的な足場で、成功したらスクリプトが自ら削除する
  （元 HEAD は reflog から辿れる）。`backup/rebase-*` が残っていたら swap が失敗した証拠なので、
  その確認と削除は人間の仕事（エージェントによる削除は deny-history.sh が deny する）

## 注意事項

- squash 後の commit は `--no-verify` で作られる。内容は元コミット時点で hook を通過済みの
  内容保存変換であり、配布先の commit hook（フォーマッタ等）が tree を書き換えると
  tree 同一性検証が壊れるため
- author date は失われる（squash とは元々そういう操作）。identity は git config の本人のまま、
  Co-Authored-By 等の AI 署名は入らない — commit-gate.sh と同じ契約をスクリプトが内蔵する
- commit message は group の subject 1 行のみで body は付けない。何をまとめたかを元履歴で
  確認したい場合は reflog の元 HEAD を辿る（squash 直後の報告に元 HEAD の sha を出す）
- 本スキルは AGENTS.md「Git 運用」の従属物。規約が変わったら本スキルより規約が優先
