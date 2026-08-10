# 設定配布元リポジトリ

このリポジトリはClaude Code・Codex向け設定の配布元であり、application repositoryではない。

- `AGENTS.md`、`claude/`、`codex/`、`hooks/`、`rules/`、`skills/`、`prompt/`、`e2e/`は配布用templateとして扱う
- 配置先は`README.md`の配布対応表を正とする
- 配布元固有の変更と、配布先で有効になる変更を区別する
- `SOURCE_REPOSITORY.md`、`tests/`、localの`.claude/`・`.codex/`は配布しない
- `bootstrap`は配布後のcopyで実行し、このリポジトリ自身へ実行しない
- 配布物を変えたらClaude Code・Codex両方の配置シミュレーションを通す
- 配布物を変えたら適切な粒度で `git add` と `git commit` する
