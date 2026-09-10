---
name: rebase
description: "明示的な$rebaseで、未pushの1ファイル1コミット履歴を機能単位へsquashする。"
allowed-tools: Read, Grep, Glob, Bash
disable-model-invocation: true
---

## 前提検査

`$rebase`を未push履歴整理の許可として扱い、追加承認を求めない。履歴操作は次のスクリプトだけを使い、Git規約に従う。

```bash
bash [skills_root]/rebase/rebase.sh --check [--base <ref>]
```

| 検査結果 | 対応 |
|---|---|
| clean、mergeなし、全remote refから対象commitが不可視 | 分類へ |
| subject契約外のcommit | それ以前は対象外 |
| upstreamなし | `--base`必須。未指定なら停止 |
| `NOTHING-TO-DO` | 対象なしと報告して終了 |
| 検査失敗 | 履歴を変更せず停止 |

## 分類・実行

checkが返すcommit・変更fileを古い順に分類する。

| 変更 | group |
|---|---|
| APIとvalidation schema／migrationとschema／helper・定数への置換と利用箇所／testと対象実装 | 各組を同じgroup |
| component | component単位 |
| lint・format | 対象fileのgroup |
| 判別不能 | 独立group |

同一fileを変更するgroupが履歴内で交差する場合は確認し、必要なら併合する。checkの短縮SHAと`SUBJECT_FORMAT`をそのまま使う。scratch file・full SHA化・format再取得は不要。

```bash
bash [skills_root]/rebase/rebase.sh [--base <ref>] \
  --group '<subject 1>' '<sha1>,<sha2>' \
  --group '<subject 2>' '<sha3>'
```

group順が完成履歴の順序となり、group内は元履歴順に処理される。

- 成功：全commitのexactly-once消費・tree一致を検証後、旧HEADを照合してswapする
- conflict：groupを併合するか、元履歴の連続範囲だけをまとめて再実行する
- 空group：revertとの相殺を確認して組み直す
- 並行commit・検証失敗：更新を拒否する
  - 検証中のindex・作業file変更は保持する

## 報告

完成履歴、元HEAD、exactly-once・tree一致の結果を報告する。

成功後のbackupは残さず、元HEADはreflogから参照できる。`backup/rebase-*`が残ったら報告し、削除はユーザーに任せる。
