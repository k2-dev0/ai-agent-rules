---
name: bootstrap
description: "配置済み設定のplaceholderを解決し、成功後にbootstrapを削除する。"
allowed-tools: Bash
disable-model-invocation: true
---

## 実行

引数の`claude`／`codex`を使う。未指定は確認し、未知の値は配置先を確認して`bootstrap.sh`のcase対応後に実行する。

| agent | 設定・hooks・rules・prompt | skills_root |
|---|---|---|
| claude | .claude | .claude/skills |
| codex | .codex | .agents/skills |

次をプロジェクトルートから**最初のツール呼び出し**として単独実行する。事前のRead・Grep・Glob・pwd・git status・設定確認は行わない。

```bash
bash [skills_root]/bootstrap/bootstrap.sh <agent>
```

表のpathと引数へ置換し、コマンド形式を変えない。sed・heredoc・一時スクリプトで代用しない。配布元では実行しない。

## 判定・報告

- 成功：placeholderの置換・検査とbootstrapの削除が完了
  - 置換値と削除結果を報告する
  - 追加grepは不要
- 失敗：失敗した場合だけ [FAILURES.md](FAILURES.md) を読み、復旧後に再実行する
  - 初期化・削除開始の失敗時はbootstrapを残す
- quarantine cleanupのwarningのみ：skill探索からの除外は完了
  - 残存pathを報告する
