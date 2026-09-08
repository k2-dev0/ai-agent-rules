# ai-agent-rules

Claude Code／Codex向けの規約・skill・hookの配布テンプレート。

## 配置

`AGENTS.md`、`claude/`、`codex/`、`hooks/`、`rules/`、`skills/`、`prompt/`、`e2e/`を配布する。`SOURCE_REPOSITORY.md`、`tests/`、配布元のローカル`.claude/`・`.codex/`は配布しない。

### Codex（0.138.0以上）

| 配布元 | 配置先 |
|---|---|
| `AGENTS.md` | `<repo>/AGENTS.md` |
| `codex/config.toml` | `<repo>/.codex/config.toml` |
| `codex/hooks.json` | `<repo>/.codex/hooks.json` |
| `codex/.gitignore` | `<repo>/.codex/.gitignore` |
| `codex/agents/` | `<repo>/.codex/agents/` |
| `codex/rules/default.rules` | `<repo>/.codex/rules/default.rules` |
| `hooks/` | `<repo>/.codex/hooks/` |
| `rules/` | `<repo>/.codex/rules/` |
| `prompt/` | `<repo>/.codex/prompt/` |
| `e2e/` | `<repo>/.codex/e2e/` |
| `skills/` | `<repo>/.agents/skills/` |

### Claude Code

| 配布元 | 配置先 |
|---|---|
| `AGENTS.md` | `<repo>/AGENTS.md` |
| `claude/CLAUDE.md` | `<repo>/CLAUDE.md` |
| `claude/.mcp.json` | `<repo>/.mcp.json` |
| `claude/settings.json` | `<repo>/.claude/settings.json` |
| `claude/settings.local.json` | `<repo>/.claude/settings.local.json` |
| `claude/.gitignore` | `<repo>/.claude/.gitignore` |
| `claude/agents/` | `<repo>/.claude/agents/` |
| `hooks/` | `<repo>/.claude/hooks/` |
| `rules/` | `<repo>/.claude/rules/` |
| `prompt/` | `<repo>/.claude/prompt/` |
| `e2e/` | `<repo>/.claude/e2e/` |
| `skills/` | `<repo>/.claude/skills/` |

### 初期化・更新

1. `setup-agent`で配置する。初回・`--update`ともcontext-dictionaryの実pathと`[agent_name]`・`[skills_root]`を解決し、検証・bootstrap削除後に起動する。起動省略時も初期化し、失敗時は起動しない。
2. 手動配置では`__CONTEXT_DICTIONARY_ROOT__`を実pathへ置換し、projectをtrustしてから次を実行する。`setup-agent`利用時は不要。

```text
# Claude Code
/bootstrap claude
# Codex
$bootstrap codex
```

3. Codexは`/hooks`で初期化後の定義をレビュー・信頼し、再起動する。hook変更時も再レビューする。未trustのproject-local設定は適用されない。
4. Claudeはproject rootの`.mcp.json`にあるSerena・context-dictionaryを承認する。両環境ともcontextのsearch/getは自動、upsert/follow_upは確認する。

更新前に利用先の設定・設計書・`AGENTS.override.md`を比較する。旧`require-test.sh`と登録、`skills/tdd/preflight-implementer.sh`、旧bootstrapの`[NOTE]`処理、tdd／errandの`require-implementer.sh workflow`登録、旧implementer定義・`IMPLEMENTER_CONTRACT.md`・`IMPLEMENTER_LAUNCH.md`は削除し、設定・hook・skillの版を揃える。外部`setup-agent`の更新・削除処理は本リポジトリの検証対象外。

bootstrapは配置先だけで実行する。`.[agent_name]`のdotはplaceholderの外へ置く。置換・残存検査・自己削除は`bootstrap.sh`が行う。ClaudeのルートCLAUDE.mdは`@AGENTS.md`を参照し、CodexはAGENTS.mdを直接読む。

## skill・共通資料

| 入口 | 処理 |
|---|---|
| [meeting](skills/meeting/SKILL.md) | 明示起動でpreflight → cowlick → ponytail。設計書を直接作成・簡素化 |
| [tdd](skills/tdd/SKILL.md) | 引数なしで先頭未完了設計書1枚を実装・レビュー・polish |
| [errand](skills/errand/SKILL.md) | 明示起動で既存パターンの小修正・定型追加。設計書なし |
| [polish](skills/polish/SKILL.md) | verifiedの実変更path、またはdirectの明示pathを整形・検証。directの完全性はscope-unverified |
| [unwind](skills/unwind/SKILL.md) | polish内部で3段以上の制御フローネストを検出・縮退 |
| [rebase](skills/rebase/SKILL.md) | 未pushの1ファイル1コミット履歴を機能単位へsquash |
| [e2e](skills/e2e/SKILL.md) | 計画を承認・保存し、ブラウザで検証 |
| [dictionary](skills/dictionary/SKILL.md) | 知見を検索・取得し、承認後に保存・更新 |
| [bootstrap](skills/bootstrap/SKILL.md) | 手動配置後の初期化 |

調査・要件・設計・実装・レビュー・テスト・Gitはメインが担当し、残作業に応じてモデルを切り替える。並列実行は禁止。サブエージェントは読み取りの文脈隔離・独立レビューに限り、1体ずつ起動して完了までメインも待機する。ネストの独立検出には読み取り専用nesting-reviewerを使う。

Codexの子はLuna/maxだけを起動hookで許可し、Claudeの子はSonnet/maxを使う。Codexの短い子待機はhookで60秒へ補正する。会話継承・短周期poll・全文ログ再取得は避ける。詳細は[子・待機の規則](skills/SUBAGENT_RULES.md)。

hookの強制は、配置済み設定を読むtrusted projectと対応toolで有効。Codex本体の待機上限・再推論・利用量計算は変更しない。

| 正本 | 内容 |
|---|---|
| [MODEL_SELECTION.md](skills/MODEL_SELECTION.md) | メインモデルの選択 |
| [IMPLEMENTATION_RULES.md](skills/IMPLEMENTATION_RULES.md) | 共通判断と該当規約への入口 |
| [SCENARIO_FLOW.md](skills/SCENARIO_FLOW.md) | 調査・シナリオ選択・Red・実装・Green |
| [REVIEW_FLOW.md](skills/REVIEW_FLOW.md) | 差分検証・診断分類・修正担当・最終レビュー |
| [DESIGN_FORMAT.md](skills/cowlick/DESIGN_FORMAT.md) | 設計書の形式・実装情報 |


## 設定・hook

明示起動skillはClaudeの`disable-model-invocation: true`とCodexの`agents/openai.yaml`の`allow_implicit_invocation: false`を設定する。[起動policy](https://learn.chatgpt.com/docs/build-skills#optional-metadata)。

| 変更・調査対象 | ファイル |
|---|---|
| Claudeの許可・確認・禁止 | `claude/settings.local.json` |
| Codexの権限・network・MCP | `codex/config.toml` |
| Codexのcommand規則 | `codex/rules/default.rules` |
| hook配線 | `claude/settings.json`、`codex/hooks.json` |
| hook入出力 | `hooks/shell/hook-io.sh` |
| 読み取りcommand・AWS readonly | `hooks/shell/readonly-search.sh` |
| shell上書き・redirect | `hooks/shell/shell-file-write.sh` |
| 設定・秘密情報・lockfile・確認対象 | `protect-config.sh`・`protect-env.sh`・`protect-locks.sh`・`protect-review.sh`（hooks/shell配下） |
| migration／履歴制限 | `hooks/shell/deny-migration.sh`・`hooks/shell/deny-history.sh` |
| 全面Write確認・commit契約 | `hooks/shell/overwrite.sh`・`hooks/shell/commit-gate.sh` |
| 必須資料・子の直列起動の検査 | `hooks/shell/load-required-contract.sh`・`hooks/shell/require-implementer.sh` |

Codexの子は`max_threads = 1`で同時起動数を制限する。hookは実装委任・background・一括起動・resumeを拒否する。nesting-reviewerのmodel・effortは専用定義を使う。

| 操作 | 扱い |
|---|---|
| 単一読み取りcommand、ps -p、安全な/dev/null出力 | 自動 |
| AWS CLIで`--profile daresuma-readonly`を明示 | service/actionを限定せず自動 |
| 通常file・promptのEdit/apply_patch、新規Write、metadata変更、mkdir | workspace内で自動 |
| `cp -n -- SOURCE DEST`・`ln [-s] -- SOURCE DEST` | 既存宛先を置換せず実行 |
| 既存fileの全面Write | Claudeで確認。Codexはapply_patch |
| 承認済みtestを`./base/scripts/run-unit.sh`で実行 | 自動 |
| schema.prisma編集、Prisma format/validate/generate | 自動 |
| package.json・CI・migration file・Docker・Terraform編集、削除 | 確認 |
| localhostを含むHTTP | sandbox外で確認 |
| 単一file・対象名一致・日本語・AI署名なしの契約準拠commit | 自動 |
| shell上書き・mv・sed -i・tee・redirect、複合command・危険option | 拒否。内容変更はEdit/apply_patch |
| .env・lockfile・.git・agent設定の直接変更 | 拒否。設定更新は固定スクリプト |
| skill内スクリプトの直接表示・内容検索・trace実行 | hookで拒否。文書・ファイル名一覧・通常実行は維持。実行に問題があれば報告して停止 |
| Prisma migrate/db push/db execute、Git push/cherry-pick、依存install/add | 拒否 |
| 複数stage・対象名不一致・日本語なし・AI署名・amendのcommit | 拒否 |

Codexのpath単位確認はrules経由の1回限りtokenを使う。Claudeのlocal ESLintは既定確認、Codexは固定prefixで許可する。MCPの未登録toolは両方で確認する。hookは呼び出したcommandを検査するもので、任意スクリプトの全副作用を保証しない。別スクリプトで制限を迂回しない。

## 文書の編集

skill・文書には実行条件、手順、command、判定・返却内容を書く。背景・理由・重複説明は削り、意味が変わらない範囲で短くする。共通基準は一か所に置き、必要な工程から参照する。AGENTS.mdは全行動に共通する短い指示だけにする。

## 検証

hook・skill・配布設定の変更後に実行する。前提はjqとgit。

```bash
bash tests/verify-all.sh
```

成功は`PASS=n FAIL=0`。Claude／Codexへの一時配置、placeholder解決、hookのdeny/ask/棄権、権限・commit・MCP・参照先、rebase・並行編集・専用agentを検証する。作業用directoryは終了時に削除する。

Codex CLIがあればversion・strict config・execpolicyも検証し、なければ省略する。skill形式検査は配布形式に対応した`python3 tests/validate-skills.py skills/<skill名>`を使い、全体テストでは全skillと検査器の異常系を検証する。`tests/run-tests.sh`は全体テストから呼び、単体では使わない。
