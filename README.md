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

3. Codexは`/hooks`で初期化後の定義をレビュー・信頼し、再起動する
   - hook変更時も再レビューする
   - 未trustのproject-local設定は適用されない
4. Claudeはproject rootの`.mcp.json`にあるSerena・chrome-devtools・context-dictionaryを承認する
   - 両環境ともcontextのsearch/getは自動、upsert/follow_upは確認する

更新前に利用先の設定・設計書・`AGENTS.override.md`を比較する。旧`require-test.sh`と登録、`skills/tdd/preflight-implementer.sh`、旧bootstrapの`[NOTE]`処理、`require-implementer.sh workflow`登録、旧implementer定義・`IMPLEMENTER_CONTRACT.md`・`IMPLEMENTER_LAUNCH.md`は削除し、設定・hook・skillの版を揃える。`skills/errand/`・`skills/SCENARIO_FLOW.md`・`rules/typescript/tdd-pattern.md`も削除し、設計書実装の起動を`$tdd --from-doc`へ変更する。外部`setup-agent`の更新・削除処理は本リポジトリの検証対象外。

bootstrapは配置先だけで実行する。`.[agent_name]`のdotはplaceholderの外へ置く。置換・残存検査・自己削除は`bootstrap.sh`が行う。ClaudeのルートCLAUDE.mdは`@AGENTS.md`を参照し、CodexはAGENTS.mdを直接読む。

## skill・共通資料

| 入口 | 処理 |
|---|---|
| [meeting](skills/meeting/SKILL.md) | 明示起動でpreflight → cowlick → ponytail。メインが設計書を作成・修正し、ponytailが独立監査 |
| [tdd](skills/tdd/SKILL.md) | runtime挙動の実装・修正で自動選択。質問・調査・review、文書・設定・書式だけの変更、挙動不変の整理では選択しない。`$tdd --from-doc`だけ設計書モードを読む |
| [polish](skills/polish/SKILL.md) | verifiedの実変更path、またはdirectの明示pathを整形・検証。directの完全性はscope-unverified |
| [unwind](skills/unwind/SKILL.md) | 指定された本体コードの深いネストを検出・縮退 |
| [rebase](skills/rebase/SKILL.md) | 未pushの1ファイル1コミット履歴を機能単位へsquash |
| [e2e](skills/e2e/SKILL.md) | 計画を承認・保存し、動画・screenshotを残してブラウザで検証 |
| [dictionary](skills/dictionary/SKILL.md) | 知見を検索・取得し、承認後に保存・更新 |
| [bootstrap](skills/bootstrap/SKILL.md) | 手動配置後の初期化 |

変更時は[AGENTS.md](AGENTS.md)から短い[モデル選択](skills/MODEL_SELECTION.md)を読み、方針確定後・最初の編集前に`difficulty-evaluator`で実装難度を判定する。子の起動時は親へ起動手順、子へrole専用契約をhookで分けて注入する。Codexのモデル切替手順はBatonの`PreModelSwitch`で元モデルへ一度だけ返し、Baton非対応環境だけ事前に読む。

hookの強制は、配置済み設定を読むtrusted projectと対応toolで有効。Codex本体の待機上限・再推論・利用量計算は変更しない。

| 正本 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 全変更に共通するモデル選択の目標と入口 |
| [MODEL_SELECTION.md](skills/MODEL_SELECTION.md) | 評価の適用条件、モデル対応、再利用・再評価条件 |
| [MODEL_SWITCH.md](skills/MODEL_SWITCH.md) | Batonでは切替前に元モデルへ注入し、非対応環境では切替前だけ読む手順 |
| [IMPLEMENTATION_RULES.md](skills/IMPLEMENTATION_RULES.md) | 共通判断と該当規約への入口 |
| [FIX_FLOW.md](skills/FIX_FLOW.md) | 検証失敗の分類・メインによる修正・再検証 |
| [INDEPENDENT_REVIEW.md](skills/INDEPENDENT_REVIEW.md) | reviewer起動直前に親へ注入する起動・待機・指摘対応 |
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
| 必須資料・専用の子の起動検査 | `hooks/shell/load-required-contract.sh`・`hooks/shell/require-implementer.sh` |

Codexの子は`max_threads = 1`で同時起動数を制限する。hookは専用role以外の起動・background・一括起動・resumeを拒否する。nesting-reviewerのmodel・effortは専用定義を使う。

難易度評価の起動hookは専用設定を検査する。Codexのnative `spawn_agent`では`message`がhookで解析可能な本文とは限らないため、非空の文字列であることだけを検査し、JSON・2キー・repositoryの検査は受信した評価役が行う。Claudeの`Agent`など本文を渡す形式ではhookでもbriefを検査する。方針本文への背景混入、評価時点、点数の妥当性は文書による指示であり、hookによる強制ではない。採点契約は評価役だけが読み、同じ方針の再開・修正では結果を再利用する。モデルとeffortが現在値と一致する場合は切替手順を読まない。起動失敗時に別環境へ代替しない。

評価役へモデル情報・選択基準は渡さず、返却は1〜10の点数と200文字を目安にした理由だけとする。主担当が点数をモデルへ対応させる。判定不能時は`null`を返し、主担当は編集を止める。

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

Codexのpath単位確認はrules経由の1回限りtokenを使う。Claudeのlocal ESLintは既定確認、Codexは固定prefixで許可する。両環境のchrome-devtoolsはChrome 149以上でlocalhost・127.0.0.1・::1の全ポートに限定し、PATH上の`ffmpeg`を使う実験screencastを有効化する。Codexでは`upload_file`だけ確認する。外部URLへの遷移・subresource通信は遮断する。他のMCPの未登録toolは各serverの既定設定に従う。hookは呼び出したcommandを検査するもので、任意スクリプトの全副作用を保証しない。別スクリプトで制限を迂回しない。

## 文書の編集

skill・文書には実行条件、手順、command、判定・返却内容を書く。背景・理由・重複説明は削り、意味が変わらない範囲で短くする。共通基準は一か所に置き、必要な工程から参照する。AGENTS.mdは全行動に共通する短い目標だけにし、自動選択skillの入口には通常経路だけを置く。

## 検証

hook・skill・配布設定の変更後に実行する。前提はjqとgit。

```bash
bash tests/verify-all.sh
```

成功は`PASS=n FAIL=0`。Claude／Codexへの一時配置、placeholder解決、hookのdeny/ask/棄権、権限・commit・MCP・参照先、rebase・並行編集・専用agentを検証する。作業用directoryは終了時に削除する。

Codex CLIがあればversion・strict config・execpolicyも検証し、なければ省略する。skill形式検査は配布形式に対応した`python3 tests/validate-skills.py skills/<skill名>`を使い、全体テストでは全skillと検査器の異常系を検証する。`tests/run-tests.sh`は全体テストから呼び、単体では使わない。

`test_context_delivery.py`は両配布の全matcherを再現し、hook出力のUTF-8 bytesと回数を測る。実モデルの受信証明とは区別する。`python3 tests/probe_context_runtime.py <codex|claude> <investigation|document_change|normal_implementation|from_doc|review_repair>`は認証済みCLIでの任意検証で、隔離fixture・hook出力・モデル応答を一時directoryへ保存する。project hookの発火なしは失敗とし、Codexの`--inline-hooks`診断をproject配置の成功扱いにしない。

`test_pre_model_switch.py`はBaton eventの入力・model/effortだけの同値要求・thread別receipt・文書変更・nested cwd・失敗を検証する。`BATON_ROOT=/path/to/baton bash tests/verify-all.sh`はBatonの実loader・runnerへ配布hookを接続する。`node tests/probe_baton_pre_model_switch_runtime.mjs /path/to/baton`は認証済みCodexで、旧モデルへの本文配信・1回の再試行・切替後の完了を実測する。

### 独立レビューと文書の読込

`independent-review.sh`はコード・testの最初の編集前HEADをsession別に保持し、起動された専用子の入力と`SubagentStop`のJSON結果を照合する。独立レビューが必要かはskillが判断し、`Stop`で完了を推測・阻止しない。要求の追加・訂正、編集、HEAD変更は旧結果を失効させる。

配布先は`PreToolUse`・`SubagentStart`・`SubagentStop`対応のruntimeを使う。hookを通らないtool経路や、ユーザー自身による状態変更は保証対象外。イベント仕様は[Codex hooks](https://learn.chatgpt.com/docs/hooks)を参照する。

cowlick・ponytail・polish・unwindの`SKILL.md`は明示呼び出し用の入口とし、内部工程は各配下の`PROCEDURE.md`を直接読む。tddの`FROM_DOC.md`は`$tdd --from-doc`だけが読む。

共通基準は調査後、設計・実装方針を決める前にskillから読む。子の起動と独立レビューの手順は`load-operation-context.sh`、Codexのモデル切替手順はBaton用`pre-model-switch.sh`が対象操作を一度止めて親へ注入し、role専用契約は`SubagentStart`で子だけへ注入する。注入専用文書は通常の参照から外し、対応する直接読込をhookで拒否する。文書変更のreviewerは変更fileと直接依存先だけを読む。

| 禁止・制約の種類 | 実施箇所・境界 |
|---|---|
| push・一括commit・強制stage | `commit-gate.sh`。認識対象のGitコマンドとindexを検査 |
| registry取得・Prisma反映 | `deny-registry.sh`・`deny-migration.sh`。コマンド検査。任意script内部の通信・副作用は保証しない |
| 一般調査・実装の委任、起動設定の上書き | `require-implementer.sh`。専用roleだけ許可 |
| reviewerの編集・再委任 | Codexのread-only sandboxとagents無効化。Claudeはtool制限。Bashの意味的な読み取り専用性は文書だけでは保証しない |
| 開始HEAD保持・起動済み独立レビューの証跡 | `independent-review.sh`。対象SHA・clean状態・専用子の最終結果を検査。レビューの必要性は判定しない |
| 設定・秘密・lockfile・migration fileの編集 | `protect-config.sh`・`protect-env.sh`・`protect-locks.sh`・`protect-review.sh` |
| polishの対象path・tracked・clean | `polish/capture-scope.sh`・`polish/quality-gate.sh`。検査scriptの実行自体の省略は防がない |
| assertionの弱体化・不要な抽象化・要件の推測・検証結果の誤認 | 共通基準・各工程・独立レビュー。操作名だけでは判定できないため文書に残す |
| シナリオの選択・設計revision・指摘の採否 | 各workflow。ユーザーの自然言語の意味や判断の妥当性をhookで代行しない |
| 履歴の書き換え・script経由の迂回 | `deny-history.sh`・`deny-eval.sh`。rebaseは固定実行器に限定 |
| skill実装の直接取得・既存fileの全上書き | `deny-skill-source.sh`・`overwrite.sh`。対象tool・pathを検査 |
| 短い子の完了待ち | `agent-wait.sh`がCodexのtimeoutを補正。無意味な再確認かどうかはメインが判断 |
| E2Eの承認前操作・passwordの平文保存 | E2E手順に残す。承認状態・秘密値と全browser／出力経路がhookへ連携されていない |
