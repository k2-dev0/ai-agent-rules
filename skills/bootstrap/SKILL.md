---
name: bootstrap
description: "配置済みのエージェント設定ファイル群の placeholder（[agent_name] / [skills_root]）置換および [NOTE]: bootstrap 対象 の解決を行う"
allowed-tools: Bash
disable-model-invocation: true
---

## 目的

ユーザーが配置した AGENTS.md・設定ディレクトリ・skills ツリーに含まれるテンプレート記述を、実際のエージェント種別に合わせて書き換える。

## 実行フロー

### Step 1: エージェント種別を決める

`/bootstrap claude` または `/bootstrap codex` の引数を使う。引数がなければユーザーへ確認し、未知の値なら置換値と配置先を確認する。

| 引数 | 置換値（`[agent_name]`） | 設定ディレクトリ | skills 配置先（`[skills_root]`） |
|------|--------------------------|------------------|----------------------------------|
| `claude` | `claude` | `.claude` | `.claude/skills` |
| `codex` | `codex` | `.codex` | `.agents/skills` |

- Codex の skills は `.agents/skills`、hooks / rules / prompt は `.codex` に置く。

### Step 2: 固定スクリプトを実行する

`claude` / `codex` が確定している場合、次のコマンドを**最初のツール呼び出し**としてプロジェクトルートから単独で実行する。事前の Read / Grep / Glob、`pwd`、`git status`、設定確認は禁止する。

```
bash [skills_root]/bootstrap/init-agent.sh <agent>
```

- `[skills_root]` は表の実パスへ、`<agent>` は引数へ置き換える。文字列、相対パス、単独実行を変えない。
- sed / heredoc / 一時スクリプトで代用しない。
- スクリプトは placeholder 置換、`[NOTE]: bootstrap 対象` の解決、置換漏れ検査を行う。全検査の成功後、配置先の `bootstrap/` を自己削除する。
- 未知のエージェントを追加する場合は `init-agent.sh` の `case` を先に実装する。
- 失敗した場合だけ [FAILURES.md](FAILURES.md) を読み、原因別の復旧手順に従う。成功時は読まない。

### Step 3: 結果を報告する

置換した `[agent_name]` / `[skills_root]` の値、解決した `[NOTE]` 箇所、`bootstrap/` の削除をユーザーに報告する。

## 注意事項

- 本リポジトリ（テンプレート元）のファイルは一切変更しない。スクリプトは配置済みツリー（`.claude` / `.codex` / `.agents` / `AGENTS.md`）のみを対象とする
- placeholder の置換漏れ確認は `init-agent.sh` の終了条件に含まれる。処理後に別の `grep` を実行しない
- `SOURCE_REPOSITORY.md` がある配布元では実行を拒否する
- 初期化または自己削除の開始に失敗した場合は `bootstrap/` を残し、復旧後に再実行できるようにする
- quarantine cleanupのwarningだけが出た場合、skill探索からの除外は完了済みとして残存pathを報告する
