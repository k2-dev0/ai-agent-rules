# ai-agent-rules

Claude Code／Codex向けの規約・skill・hookの配布テンプレート。

## 配置

`AGENTS.md`、`claude/`、`codex/`、`hooks/`、`rules/`、`skills/`、`prompt/`、`e2e/`を配布する。`SOURCE_REPOSITORY.md`、`tests/`、配布元のローカル`.claude/`・`.codex/`は配布しない。

### Codex

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

1. `setup-agent`で配置する
   - 初回・`--update`ともcontext-dictionaryの実pathと`[agent_name]`・`[skills_root]`を解決し、検証・bootstrap削除後に起動する
   - 起動省略時も初期化し、失敗時は起動しない
2. 手動配置では`__CONTEXT_DICTIONARY_ROOT__`を実pathへ置換し、projectをtrustしてから次を実行する
   - `setup-agent`利用時は不要

```text
# Claude Code
/bootstrap claude
# Codex
$bootstrap codex
```

3. Codexは対象repositoryを信頼登録し、`/hooks`で初期化後のhook定義をレビュー・信頼して再起動する
   - hook変更時も再レビューする
   - 未trustではskillsが読まれてもproject-local設定・hook・role登録は適用されない
   - role更新後は新しいタスクで、起動toolの`agent_type`と必要な専用roleが公開されていることを確認する
4. Claudeはproject rootの`.mcp.json`にあるchrome-devtools・context-dictionaryを承認する
   - 両環境ともcontextのsearch/getは自動、upsert/follow_upは確認する

更新前に利用先の設定・設計書・`AGENTS.override.md`を比較する。旧`require-test.sh`と登録、`skills/tdd/preflight-implementer.sh`、旧bootstrapの`[NOTE]`処理、`require-implementer.sh workflow`登録、旧implementer定義・`IMPLEMENTER_CONTRACT.md`・`IMPLEMENTER_LAUNCH.md`は削除し、設定・hook・skillの版を揃える。`skills/errand/`・`skills/SCENARIO_FLOW.md`・`rules/typescript/tdd-pattern.md`も削除し、設計書実装の起動を`$tdd --from-doc`へ変更する。外部`setup-agent`の更新・削除処理は本リポジトリの検証対象外。

bootstrapは配置先だけで実行する。`.[agent_name]`のdotはplaceholderの外へ置く。置換・残存検査・自己削除は`bootstrap.sh`が行う。ClaudeのルートCLAUDE.mdは`@AGENTS.md`を参照し、CodexはAGENTS.mdを直接読む。

Codexのrole定義は`codex/config.toml`の`[agents.<role>].config_file`から登録する。定義ファイルの配置やtask名だけを専用roleの適用と扱わない。シナリオ承認前の確認は[子の起動手順](skills/SUBAGENT_RULES.md#開始時の可用性確認)に従う。

## skill・共通資料

| 入口 | 処理 |
|---|---|
| [meeting](skills/meeting/SKILL.md) | preflight → cowlick → ponytailで設計・独立監査 |
| [tdd](skills/tdd/SKILL.md) | runtime挙動をテストから実装。`--from-doc`は明示指定だけ |
| [polish](skills/polish/SKILL.md) | 対象pathを整形・検証 |
| [unwind](skills/unwind/SKILL.md) | 指定コードの深いネストを検出・縮退 |
| [rebase](skills/rebase/SKILL.md) | 未push履歴を固定スクリプトで整理 |
| [e2e](skills/e2e/SKILL.md) | 計画を承認・保存し、録画と画像でブラウザ検証 |
| [dictionary](skills/dictionary/SKILL.md) | 知見の検索・取得・保存 |
| [bootstrap](skills/bootstrap/SKILL.md) | 手動配置後の初期化 |

cowlick・ponytail・polish・unwindの内部工程は各`PROCEDURE.md`を読む。明示起動の制御はClaudeのfrontmatterとCodexの`agents/openai.yaml`に置く。

| 正本 | 読む時点・責務 |
|---|---|
| [AGENTS.md](AGENTS.md) | 変更前のモデル選択・適用確認への入口 |
| [IMPLEMENTATION_RULES.md](skills/IMPLEMENTATION_RULES.md) | 調査後・方針決定前の共通判断、規約・作業対象とGit状態への入口 |
| [MODEL_SELECTION.md](skills/MODEL_SELECTION.md) | 最初の編集前に親が読む。評価入力・採用モデル・適用確認・失敗・再評価 |
| [SUBAGENT_RULES.md](skills/SUBAGENT_RULES.md) | 起動入力を組み立てる前に親が読む。role・完了待ち・入力訂正・利用不能時の行動 |
| [CHILD_RULES.md](skills/CHILD_RULES.md)と各role契約 | 子の開始時に子だけへ注入。調査範囲・実行制約・返却内容 |
| [INDEPENDENT_REVIEW.md](skills/INDEPENDENT_REVIEW.md) | コードreviewerの入力を組み立てる前に親が読む。JSON入力と指摘対応 |
| [REVIEW_SEVERITY.md](skills/REVIEW_SEVERITY.md) | reviewerと親が同じ基準で成立条件・実害・影響範囲から重大度を判定 |
| [MODEL_SWITCH.md](skills/MODEL_SWITCH.md) | BatonのPreModelSwitchで元モデルへ注入。非対応環境だけ切替前に読む |
| [FIX_FLOW.md](skills/FIX_FLOW.md) | 検証失敗・採用した指摘の修正時 |
| [DESIGN_FORMAT.md](skills/cowlick/DESIGN_FORMAT.md) | 設計書作成時。モデルが生成する形式・実装情報 |

## 設定・実施箇所

| 対象 | 正本 |
|---|---|
| Claudeのtool権限／sandbox | `claude/settings.local.json`／`claude/settings.json` |
| Codexの権限・network・MCP／command規則 | `codex/config.toml`／`codex/rules/default.rules` |
| hook配線・入出力 | `claude/settings.json`、`codex/hooks.json`、`hooks/shell/hook-io.sh` |
| Git引数・.git path保護 | `protect-git.sh`・`git-policy.py`と両環境のsandbox設定 |
| 固定scriptの保存先・一時領域・Git環境 | `safe-files.py`・`git-safe-env.sh` |
| stage・commit契約 | `commit-gate.sh`・`commit-subject.sh` |
| 単一command・境界外承認・MCPのOS保護 | `git-policy.py`・`command-approval.sh`・`outside.sh`・`mcp-protected.sh`・`protected-exec.py` |
| 設定・秘密・lockfile・確認対象 | `protect-config.sh`・`protect-env.sh`・`protect-locks.sh`・`protect-review.sh` |
| 全面Write・skill実装の直接取得 | `overwrite.sh`・`deny-skill-source.sh` |
| 設計形式・子の共通制約と専用契約・role起動 | `load-required-contract.sh`・`load-operation-context.sh`・`require-implementer.sh` |
| 検証済みの子入力・実child IDへの結合 | `agent-input.py`・`agent-input.sh`・`load-operation-context.sh` |
| shellを含む変更前HEAD・起動済み独立レビューの証跡 | `independent-review.sh`・`safe-files.py` |
| Codexの待機時間補正 | `agent-wait.sh` |

hook名だけの項目は`hooks/shell/`配下。MCPの接続先・version・tool権限は設定を正本とする。録画条件・passwordの扱いは[E2E手順](skills/e2e/SKILL.md)に従う。

Gitは`git-policy.py`が列挙する読み取り用途、契約検査を通るadd/commit、`git restore --staged`によるindex復元を許可する。restoreは対象path・`--source`・pathspec file等を指定でき、worktree変更・対話patch・再帰submodule更新は拒否する。履歴整理は固定rebaseスクリプトだけを使う。外部diff・textconv・fsmonitor・pagerを無効化し、他のGit操作は拒否する。固定rebaseも外部hook・署名・filterを無効化し、一時worktreeでは保存済みblobを使う。

通常の単一commandは、種類を列挙せずsandbox内で原則自動実行する。コピー・削除・上書き・interpreter・test・package操作も含む。複合command・loop・pipeline・command substitutionは拒否し、変数展開やquote内の記号とは区別する。Gitは上記の専用境界に従う。

境界外の実行は`command-approval.sh`が`bash .<agent>/hooks/shell/outside.sh '<単一command>'`への再試行を案内し、人間の承認を待つ。入口は承認後も現在repositoryのGit metadata・保護設定・hookの内部状態をOSで書き込み禁止にする。保護を起動できなければ実行しない。stdio MCPも同じOS保護で起動する。起動directoryはrepository rootとする。

通常commandへのsandbox外allowは置かない。特権例外は契約付きadd/commit・検査済みindex復元と固定のbootstrap・設計書完了mark・E2E計画保存・rebaseに限定する。Claudeはsandboxの自動許可を有効にし、保護付き入口以外の任意のsandbox解除を無効にする。

## 保証範囲

hookは設定を読み込んだtrusted projectと対応toolで有効。project設定の存在・hook単体テスト・task名だけでは、runtimeへの適用や専用roleの適用を証明しない。[Codex hooksのtool coverage](https://learn.chatgpt.com/docs/hooks#tool-coverage)を参照する。

| 強制される部分 | 残る判断・境界 |
|---|---|
| 起動引数のrole・設定上書き・background・一括起動・追送・resume拒否、Codexの同時起動数 | 親の作業停止・環境間代替禁止・入力の意味・実際のrole metadata。起動不能は成功にしない |
| 子のrole・model・effortと共通制約の配信 | roleファイルのsandbox設定の実効性はruntime依存。Codex 0.154.0のnative起動で親のworkspace-write継承を確認したため、子をOSでread-onlyに強制済みとは扱わない。編集・test実行・調査範囲・外部通信の制約は子の共通契約に残す |
| reviewer入力・対象SHA・tracked状態・SubagentStopの結果形式、shell後に古くなった結果の失効 | reviewの必要性、指摘の妥当性・採否、関連するignored / untracked資産。形式検査は内容の自動生成ではない |
| polishのpath列挙・一致・追跡・clean検査 | script実行の省略は防がない。directの完全性はscope-unverified |
| 直接tool入力の.git path・Git引数、Chromeの保存先を検査 | 文字列検査は任意script内部の保証ではない。scriptと子processの書き込みはOS保護で止める |
| 固定scriptはリンクを拒否し、親directoryを開いてからfileを置換。一時領域も外部commandの起動前に検査 | 外部processによるdirectory移動など、同時のfilesystem変更すべてを制御するものではない |
| 初期化前の例外はbootstrapの正規argvだけ | task名・文章・file pathへのbootstrap名の混入では解除しない |
| sandbox内の.git制限と、保護付き境界外入口・配布stdio MCP内のOS制限 | 上位設定の既存allowによる直接の外部実行、別のMCP／未対応tool、既存外部serviceへ処理を委ねる経路はこの入口を通らない |

.gitの承認解除は禁止する。macOSはSeatbelt、Linuxはbubblewrapを使う。既存hardlink・保護tree内symlinkは実行前に拒否する。Linuxでは未作成の保護pathの最寄り既存親もread-onlyにするため、通常書き込みが狭まる場合がある。未対応OS・backend不在・二重sandboxの失敗を無保護の再実行へ切り替えない。

検証済み経路と適用外を区別する。上位設定や外部processの並行変更までrepositoryの設定だけで完全保護したとは扱わない。[権限profileの適用範囲](https://learn.chatgpt.com/docs/permissions#scope-and-enforcement)を参照する。

親の手順は正本への参照で事前に読む。Codexの難度評価・独立コードレビューは`agent-input.py prepare`で入力を検査・固定し、生成された起動引数を使う。暗号化messageをJSONと誤認せず、SubagentStartで実child ID・roleと検証済み入力を結び付け、共通制約・専用契約とともに渡す。準備済み入力は評価・レビュー成功の証拠ではない。標準hook入力には現在modelはあるがeffortの適用確認は含まれないため、実際のモデル・effortの確認と利用不能時の判断は親の手順に残す。

## 文書の編集

適用条件・実行入口・判断基準・結果後の行動を残す。hook・設定で強制する制約とscriptが生成する形式は重複させない。モデル自身が生成する内容の指示は残す。共通判断は正本に集約し、既読文書を必要なく読み直させない。

## 検証

前提はgit・jq・Python 3.8以上。配布物の変更後に実行する。

```bash
bash tests/verify-all.sh
```

Claude／Codexへの一時配置・bootstrap・hookの決定と子への文書配信・親の手順参照・入力訂正・固定script・専用role入力・Git境界を検査する。Codex CLIがあればstrict config・execpolicyも確認する。文書の静的検査は動作保証とは分け、実モデルが評価→切替→編集→レビューを完走した保証にはしない。

`python3 tests/test_git_policy.py`は両配布のGit guardへ入力し、許可された読み取りと外部helperの抑止をfixtureで実行する。`python3 tests/test_git_sandbox.py`はインストール済みCodexのOS sandboxで、隔離した.gitへの書き込み・コピー・リンク・親directory移動を試す。後者はsandboxを二重起動できない環境では外側の実行承認が必要。通常suiteの成功だけではOS境界の検証済みとはしない。

`test_command_permissions.py`は両配布の実際のhook配線で、通常command・複合拒否・保護付き入口への承認引き渡しを検査する。`python3 tests/test_protected_exec.py`は外側のsandboxなしで実行し、両配布の境界外／MCP入口で実際のコピー・上書き・削除・リンク・親directory移動の拒否と、通常書き込み・境界外書き込み・loopback通信の成功を確認する。macOSで実機検証し、Linuxの実機成功はこの結果に含めない。

`test_fixed_script_git_protection.py`は固定scriptを実行し、metadata alias・TMPDIR差し替え・外部Git helperを拒否／抑止しながら通常の保存・rebaseが成功することを検査する。

`python3 tests/test_role_runtime.py`はsandbox外で実行し、一時Codex領域・local模擬API・実CLIで入力準備→native起動→配布hook→子契約→結果受理を通し、app-serverで`agentRole`／`agent_role`を照合する。要求されたmodel・effort、未信頼project、未対応の切替を成功にしないことも検査する。外部モデルの評価は行わない。`--probe-permissions`は子の実書き込みも試す追加診断で、role登録の成功をOS read-onlyの成功とは扱わない。

`python3 tests/probe_agent_workflow.py --case workflow`は認証済みCodexで難度評価・Red/Green・個別commit・独立レビュー受理を通す実モデル検査。CLIの切替不能時の降格継続と、Batonの実モデル切替検査を区別して記録する。hook未発火・子未開始・不正結果・レビュー未受理・Red/Green欠落は失敗とし、通常suiteや模擬応答の成功で代替しない。

skill形式は`python3 tests/validate-skills.py skills/<skill名>`で検査する。`tests/run-tests.sh`は全体suite経由で使う。

認証済みCLIの親子配信probeとBatonの実loader／実モデルprobeは[検証記録](tests/context-delivery-report.md)を参照する。未発火のproject hook、未開始の専用子、inline配線だけの成功を配布の実機成功として扱わない。
