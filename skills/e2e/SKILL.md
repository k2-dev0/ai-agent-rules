---
name: e2e
description: "chrome-devtools-mcpでE2E計画の保存・実行・結果報告を行う。"
allowed-tools: Read, Grep, Glob, Bash, mcp__chrome-devtools__*
disable-model-invocation: true
---

## モード

| 引数 | 処理 |
|---|---|
| なし | 情報収集 → 計画承認 → 保存 → 実行 → 報告 |
| `save` | 情報収集 → 計画承認 → 保存して終了 |
| `run` | 保存済み`@.[agent_name]/e2e/.e2e.md`を再質問せず実行 |

他の引数は受け付けない。

## 計画・保存

引数なし／saveでは、対象URL・ページ・component、必要なログインURL・ID・password、前提、完了条件を一件ずつ確認する。回答済み・不要な質問は省略する。ページ・componentからURLを調べ、未指定の前提・完了条件は実装から補って提示する。

対象、マスクしたログイン情報、前提、完了条件、順序付きシナリオを提示し、承認後に一時ドラフトを次で保存する。承認前にブラウザを操作せず、保存先を直接編集しない。

```bash
bash [skills_root]/e2e/apply-e2e-plan.sh <ドラフトのパス>
```

## 実行・判定

chrome-devtools-mcpで必要なログイン後、シナリオ順に実行する。

- 各操作後にscreenshotを取得する。
- error・表示崩れは状態と再現手順を記録する。
- シナリオごとの期待結果と全体の完了条件を判定する。
- 破壊的操作は直前に確認する。外部service・本番dataへの影響は伝え、継続判断を求める。

全体を「合格／不合格／一部不合格」、各シナリオを結果表で報告する。不合格は問題・再現手順・screenshotを付ける。

passwordはセッション内だけで使い、ログ・comment・計画へ平文保存しない。終了後は一時screenshotを片付け、browserを閉じる。
