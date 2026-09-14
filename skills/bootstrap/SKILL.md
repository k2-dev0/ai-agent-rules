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

表のpathと引数へ置換する。

## 判定・報告

- 成功：scriptの出力を報告して終了する
- 失敗：失敗した場合だけ [FAILURES.md](FAILURES.md) を読み、復旧後に再実行する
- warningのみ：残存pathを報告する
