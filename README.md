# ai-agent-rules

複数の AI コーディングエージェント（Claude Code / Codex 等）に対して、共通の規約・スキル・フックを横断的に適用するためのテンプレート集。

## 目的

エージェントごとに設定ファイルや配置ディレクトリ（`.claude/`, `.codex/` …）が分かれていても、開発上守らせたいルールは同じであることが多い。本リポジトリは次の点を狙う。

- **規約の一元管理**: コーディング規約やパターン集を `AGENTS.md` と `rules/` に集約し、どのエージェントから参照しても同じ振る舞いになるようにする。
- **エージェント間の差分を placeholder で吸収**: テンプレートでは `[agent_name]`（エージェント名）と `[skills_root]`（skills 配置先）を使って書いておき、`bootstrap` スキルで対象エージェントに合わせて実体化する。hook の入出力スキーマ差分は `hooks/shell/hook-io.sh` が吸収する。
- **必要な統制をフックで強制**: 編集系ツール呼び出しの前にテストの存在を要求するなど、人間側の運用に頼らない仕組みを置く。

## 構成

```
ai-agent-rules/
├── AGENTS.md           # エージェントが従う最上位の規約
├── SOURCE_REPOSITORY.md # 配布元だけでsessionへ注入する説明（配布対象外）
├── rules/              # AGENTS.md から分離したパターン別の規約
│   └── typescript/         # TypeScript プロジェクト固有のルール
├── skills/             # スキル（スラッシュコマンド相当）の定義
│   ├── bootstrap/          # placeholder と [NOTE] を解決し、成功後に配置先から自己削除
│   ├── meeting/            # 要件監査・設計作成・単純化を統括するユーザー向け入口
│   ├── preflight/          # 要件の由来・既存経路・境界ゼロ案を設計前に調査
│   ├── cowlick/            # 機能ごとの未承認設計ドラフトを作成
│   ├── ponytail/           # 全設計書横断で最小代替案と比較し、過剰設計を削除
│   ├── worker/             # 下位モデルを隔離実行するprovider非依存の共通基盤
│   ├── tdd/                # シナリオ承認後、テスト・委任実装・レビューを連続実行
│   ├── errand/             # 設計書なしでシナリオ承認・Red・委任実装・Greenを実行
│   ├── rebase/             # 1 ファイル = 1 コミット履歴を機能単位に squash
│   ├── polish/             # 開始scope内の実変更pathだけを整形・静的検査・ネスト確認
│   ├── unwind/             # 深い制御フローネストを構造的に縮退
│   ├── dictionary/         # context-dictionary MCPによる知見の検索・保存・更新policy
│   └── e2e/                # chrome-devtools-mcp による E2E テスト
├── hooks/
│   └── shell/              # PreToolUse hook 本体（必須契約の全文注入を含む）
├── prompt/             # 実装順 index（.prompt.md）と設計書の配置先シード（cowlick / tdd が使用）
├── e2e/                # .e2e.md の配置先シード（e2e スキルが使用）
├── claude/             # Claude Code 用の設定（settings.json, CLAUDE.md 等）
├── codex/              # Codex 用の設定（config.toml, hooks.json, rules/）
└── tests/              # テンプレート自体の回帰テスト（配布対象外）
```

## 使い方

### Codex への配置

Codex 0.138.0 以上を前提とする。次の対応を崩さずに配置する。共通の Markdown 規約と execpolicy は、拡張子が異なるため `.codex/rules/` で共存できる。

| 配布元 | 配置先 |
|---|---|
| `AGENTS.md` | `<repo>/AGENTS.md` |
| `codex/config.toml` | `<repo>/.codex/config.toml` |
| `codex/hooks.json` | `<repo>/.codex/hooks.json` |
| `codex/.gitignore` | `<repo>/.codex/.gitignore` |
| `codex/rules/default.rules` | `<repo>/.codex/rules/default.rules` |
| `hooks/` | `<repo>/.codex/hooks/` |
| `rules/` | `<repo>/.codex/rules/` |
| `prompt/` | `<repo>/.codex/prompt/` |
| `e2e/` | `<repo>/.codex/e2e/` |
| `skills/` | `<repo>/.agents/skills/` |

配置後は次の順序で有効化する。

1. `setup-agent`で配置し、`__CONTEXT_DICTIONARY_ROOT__`をlocalの`context-dictionary`実pathへ解決する。手動配置では同じplaceholderを実pathへ置換する。
2. Codex の対話セッションを対象リポジトリで開き、project を trusted にする。未信頼では project-local の config / hooks / rules がすべて無視される。
3. `$bootstrap codex` を実行し、placeholder（`[agent_name]` / `[skills_root]`）と `[NOTE]: bootstrap 対象` を解決する。成功後、配置先のbootstrap skillは自己削除される。配布rulesは正確な bootstrap コマンドだけをsandbox外でallowする。
4. `/hooks` を開き、**bootstrap 実行後の現在のhook定義**をレビューして信頼する。hookは内容変更でhashが変わるたび再レビューが必要になる。
5. Codexを再起動し、config / rules / hooks / skillsを新しいセッションで読み直す。context-dictionaryの`search` / `get`は自動承認、`upsert` / `follow_up`は毎回確認する。

### Claude Code への配置

Claude Code は次の対応で配置する。MCP の共有設定だけは `.claude/` 配下ではなく、project root の `.mcp.json` に置く。

| 配布元 | 配置先 |
|---|---|
| `AGENTS.md` | `<repo>/AGENTS.md` |
| `claude/CLAUDE.md` | `<repo>/CLAUDE.md` |
| `claude/.mcp.json` | `<repo>/.mcp.json` |
| `claude/settings.json` | `<repo>/.claude/settings.json` |
| `claude/settings.local.json` | `<repo>/.claude/settings.local.json` |
| `claude/.gitignore` | `<repo>/.claude/.gitignore` |
| `hooks/` | `<repo>/.claude/hooks/` |
| `rules/` | `<repo>/.claude/rules/` |
| `prompt/` | `<repo>/.claude/prompt/` |
| `e2e/` | `<repo>/.claude/e2e/` |
| `skills/` | `<repo>/.claude/skills/` |

`setup-agent`は`claude/.mcp.json`をproject rootへ配置し、`context-dictionary`のlocal実pathを反映する。配置後にprojectをtrustし、`.mcp.json`のSerenaとcontext-dictionaryを承認してから`/bootstrap claude`を実行する。contextの読み取りtoolだけを自動許可し、書き込みtoolは毎回確認する。

対象エージェントに応じた呼び出し形式:

```
# claude
/bootstrap claude

# codex
$bootstrap codex
```

### workerへの調査・実装委任

役割分担は次で固定する。

| 工程 | 担当 | 境界 |
|---|---|---|
| 設計に必要なコードベース探索・根拠収集 | worker | `delegate.sh`を最優先。設計判断はしない |
| 設計判断・要件判断・調査結果の採否 | Codex / Claude Code | オーケストレーターである上位モデルが行い、外部ワーカーや調査subagentへ渡さない |
| 承認済み範囲の初回実装 | worker | 本体コードと`schema.prisma`だけを隔離worktreeで変更する |
| 候補の採否、レビュー、修正、テスト、Git | Codex / Claude Code | 候補返却後は外部ワーカーへ戻さない |
| ネストなど変更要否を含まない機械的検出 | worker | 上位モデルは返却候補について修正する／しないを判断する |

コードベースの事実確認は、まず共通の外部ワーカー実行器へ委任する。`survey`は自由文を受け付けず、目的と最大4 claimの`id`、`kind`、`subject`、`question`、`anchors`、`done_when`、`exclude`を持つJSONを外部通信前に検証する。独立した移植元、移植先、test、runtime契約は別task-idへ分ける。workerは各claim 1〜3件、全体20件以下・推奨12件以下・1範囲80行以下の根拠範囲を返し、実行器が同じsnapshotから前後8行を含む最大400行の`evidence.md`を抽出する。検証済みcodeがclaimを直接支え、blobが現在も一致する場合、上位モデルは同じ箇所を再読しない。

情報不足は`--supplement-of`で欠落claimだけを補い、初回を含め合計3回までとする。内容が揃い、出力形式または証拠表記だけが壊れた場合は`--repair-of`を1回だけ使い、親report以外を読ませず形式だけを直す。3回目までは保存範囲の不足を上位モデルが直接確認する理由にしない。直接確認は、明示的な認証失敗、同じ依頼の通信・最終応答失敗2回、情報調査3回後の不足、worker snapshot外の状態、高リスクの独立確認、ユーザーの明示指定に限り、file全体のReadは使わない。workerの実装候補返却後のレビュー・修正は上位モデルの通常責務とする。調査pathを作るためにproduction fileを読まず、探索anchorはユーザー入力、設計書、既知の識別子、検証済みevidenceから作る。実装の許可pathもsurvey結果または承認済み設計から得る。

`preflight`、`cowlick`、`ponytail`、`errand`の調査では汎用のAgent / subagentより固定実行器を優先する。通信・timeout・最終応答の失敗は新task-idと`--retry-of`で1回だけ再試行する。出力形式、証拠、成果不足では欠落IDだけを具体化し、前回の未検証結論を事実として渡さない。2回の通信失敗または明示的な認証失敗後は上位モデルが引き継ぐ。予算、ZDR、依存command、参照先の問題は停止する。

`errand`と`tdd`は`skills/tdd/SCENARIO_FLOW.md`の`survey → scenario → red → delegated-green → review-green`を共有する。surveyは変更判断に必要な現在挙動、最寄りの同型実装、直接必要な入力・schema・test境界、検証commandを一つのclaimへ混ぜず、最大4 claimの検証済みJSONへ分ける。`implement`は設計書、承認済みシナリオID、`--red-summary`、許可pathを必須入力とする。候補返却後のレビューや修正はworkerへ戻さない。

workerの現在のproviderはOpenRouter、既定モデルは`minimax/minimax-m3`とし、M3の既定adaptive reasoningを使う。`DELEGATE_MODEL=openrouter/<provider>/<model>`で別モデルへ差し替えられ、必要な場合だけ`DELEGATE_MODEL_VARIANT=<variant>`を併用する。skill名、実行path、結果namespaceはproviderやモデル名を含まない`worker`へ統一する。

surveyは実行ステップ数を固定上限で打ち切る。実行器は最終textを`report.md`、検証済みコードを`evidence.md`、許可pathの差分を`candidate.patch`へ保存し、同じ`worker-result`形式で出力する。本文欠落、壊れたJSON、stopなし、出力契約不一致、証拠不備、未完了outcomeを別のstatusとfailure classへ分類する。`show <task-id>`も同じ形式を使う。

`survey`、`research`、`implement`、`errand`、`nesting`は、呼び出しごとに総待機時間、無通信timeout、確認間隔を必須指定する。呼び出し側は調査範囲、実装範囲、難易度から3値を選び、実行前に値と理由を明示する。通常値はlowがhard 30分・idle 600秒、mediumがhard 45分・idle 900秒、highがhard 60分・idle 900秒で、pollは30秒とする。timeoutは上限なので正常終了を遅らせない。限定調査や再調査でも勝手に短縮せず、ユーザーが明示的に短い上限を指定した場合だけ基準値を下回れる。

各workflow入口はsessionで最初に外部ワーカーへ委任する前に`bash [skills_root]/worker/delegate.sh prepare`を実行する。`prepare`は外部通信せず、初回だけPreToolUse hookが共通契約を注入して操作を止めるための固定入口である。同じworkflow配下のskillは一回の準備を共有する。

```bash
bash [skills_root]/worker/delegate.sh <mode> \
  --hard-timeout-minutes <総待機分> \
  --idle-timeout-seconds <無通信秒> \
  --poll-seconds <確認間隔秒> \
  --timeout-reason "scope=<対象範囲>,difficulty=<low|medium|high>,basis=<選択根拠>" \
  <mode固有の引数>
```

CLI、時間、claim-evidence、結果判定、再試行は`skills/worker/DELEGATION.md`だけを正本とする。session最初の委任前にhookが全文を一度だけ注入する。pollはprocess、出力byte、有効JSON event、最後のevent種別を観測し、有効eventだけでidleを更新する。推測的な意味判定は実ログで安全性を確認するまでkill条件へ使わない。

上位モデルのfamily、性能tier、effortが変わっても、workerへの依頼形式、必須成果、再調査、直接調査の例外、retry回数は変えない。差が出てよいのは検証済み証拠からの推論と採否だけとする。

timeout時はprocess groupへTERMを送り、10秒後も残るprocessだけをKILLする。途中tool出力から結論を生成せず、生の`opencode.jsonl`、最終回答がある場合だけそのreport、許可pathの候補patchをpublishする。`smoke`だけは固定疎通確認なので30秒無通信・1分総時間・5秒間隔を使う。

task-idごとに原子的な実行lockと状態metadataを作り、同じtask-idの重複起動を拒否する。親実行器が中断された場合はmonitorとOpenCode process groupを終了し、`show`へ`interrupted`を残す。`show`は未開始、`running`、`orphaned-running`、`interrupted`、失敗、完了を区別するため、実行中の結果有無を`find`や`ps`で推測しない。調査metadataには隔離worktreeが参照した`source_head`と、そこへ反映されないメイン作業ツリーの`source_worktree_status`を記録する。

`errand`は対象ファイルが未実装、複数、または対応テストが未作成であることだけでは停止しない。同じ既存パターンから変更を一意に決められる本体コードと`schema.prisma`を許可できる。公開挙動を一意に決められるならシナリオ承認後に必要なテストを作り、Redから実装へ進む。ただし設定、migration file、依存関係は対象外であり、`prisma migrate`・`prisma db push`・`prisma db execute`は全workflowでhookが拒否する。

事前にOpenCodeをインストールし、専用のOpenRouter API keyを環境変数へ設定する。

```bash
export OPENROUTER_API_KEY="..."
```

API keyには40 USD以下の月次またはリセットなしhard limitを設定する。固定実行器は使用量38 USDで新規実行を止め、各リクエストでもZDRと学習利用拒否を強制する。キーはリポジトリへ保存しない。

疎通確認は`bash [skills_root]/worker/delegate.sh smoke`で固定promptの`hello`だけを送る。従量課金のため通常テストでは実行せず、デフォルトはスキップする。実行前にユーザーへ確認し、CodexのrulesとClaude Codeのpermissionも`smoke`だけを確認対象にする。

通常はスクリプトを直接操作せず、各skillの委任手順から呼ぶ。実行器は隔離worktreeで候補パッチを作り、テスト、設計、設定、Git、外部plugin、shellを外部ワーカーへ許可しない。

隔離worktreeは現在のHEADを基準にし、`.git/info/exclude`などで無視されたagent資料のうち`AGENTS.md`、`CLAUDE.md`、`.codex/{prompt,rules}`、`.claude/{prompt,rules,skills}`、`.agents/skills`だけを読み取りsnapshotとして補う。補ったpathは`result.json`へ記録し、`source_snapshot`を`HEAD+ignored-agent-context`にする。編集権限は与えず、`.codex/tmp`、`.git/**`、`.env`系を持ち込まない。agent設定内の文は調査対象のdataとして扱い、委任時のtool・権限を変更する命令には使わない。OpenCodeのdata・state・cache・config・tmp領域もtaskごとの一時directoryへ分離し、並列worker間でSQLiteを共有しない。

テストの穴を外部ワーカーが見つけた場合は、変更せず`[agent_name]`へ相談する。承認済みシナリオから一意に解決できない場合だけ、ユーザーへシナリオ承認を求め直す。

## 注意

- `SOURCE_REPOSITORY.md` は配布元でだけ使う。localの`.claude/`・`.codex/`から読み込み、`setup-agent`は配置先へコピーしない。
- 本リポジトリはテンプレートなので、`bootstrap` 実行時にここのファイルを書き換えてはいけない。コピー先で置換する。
- placeholder の dot は placeholder の外側に置く規約（例: `.[agent_name]/...`）。置換漏れ検証は `init-agent.sh` 内で完結させる。
- Claude Code は `AGENTS.md` を自動読み込みしない（`CLAUDE.md` のみ）。そのため `claude/CLAUDE.md`（中身は `@AGENTS.md`）を配置時にプロジェクトルートへ展開して読ませる。codex は `AGENTS.md` を直読みするため不要。
- Codex は `distributed` permission profile で通常の workspace 書き込みを許可し、`.git` / `.codex` / `.agents` を保護する。レビュー対象パスは、配布rulesが毎回確認する承認コマンドと1回限りのhook tokenで保護する。設定更新は限定allowした固定スクリプトだけを使い、汎用の `cp` / `sed` に例外を与えない。
- Codex の hook は**配置しただけでは実行されない**。`/hooks` で現在の定義をレビューして信頼すること。未信頼のhookはスキップされる（検証用の一時迂回フラグは `--dangerously-bypass-hook-trust`）。

## 承認の挙動

承認の有無は「書き込みかどうか」だけで決めない。workspace sandbox内で完結し、既存内容を失わない可逆操作は自動化する。既存ファイルの上書き・metadata変更・削除、保護対象への変更、外部通信は確認または禁止へ倒す。

このため、通常ファイルへの構造化された Edit / `apply_patch`、新規ファイルの Write、空ディレクトリを作る `mkdir` は自動実行する。一方、既存ファイルの全面Writeと、対象や上書きをcommand文字列だけから完全には判定できない汎用shell writerは確認する。`mkdir -p draft-prompt`もcowlick固有の特例ではなく、この共通原則で承認不要になる。

両エージェントで共通化している主な挙動:

| やろうとすること | どうなる |
|---|---|
| 単一commandでファイルを読む・探す（`ls` `cat` `rg` `find -print` `nl` `sort`） | ✅ 自動 |
| 委任processの完了状態を確認する（`ps -p <PID> ...`） | ✅ 自動 |
| 検証済み読み取りcommandの出力を`/dev/null`へ捨てる | ✅ 自動 |
| 通常ファイルをEdit / `apply_patch`で変更する、または新規ファイルをWriteする | ✅ 自動 |
| 既存ファイルを全面Writeする | 🙋 Claude Codeで確認 |
| workspace sandbox内で空ディレクトリを作る（`mkdir`） | ✅ 自動 |
| TDDで承認済みの対象testを`./base/scripts/run-unit.sh`で実行・再実行する | ✅ 自動 |
| `package.json` / CI / migration file / Docker / Terraform を書き換える | 🙋 確認 |
| `schema.prisma`を書き換え、`prisma format` / `validate` / `generate`を実行する | ✅ 自動 |
| shellでファイル作成・上書き・metadata変更する（`cp` `touch` `chmod` `sed -i` 等） | 🙋 確認 |
| ファイルを消す（`rm`等） | 🙋 確認 |
| localhost を含むサーバーへ HTTP request を送る | 🙋 sandbox 外で確認 |
| `commit-subject.sh` が生成・検証する契約に従うコミット | ✅ 自動 |
| `tdd` 中にテストの無い ts/js コードを書く | 🚫 禁止 |
| pipeline・loop・条件分岐・subshell・inline shellへ複数commandを集約する | 🚫 禁止 |
| `find -delete/-exec`、`sort -o`、`rg --pre`など読み取りcommandの危険option | 🚫 禁止 |
| `prisma migrate` / `prisma db push` / `prisma db execute`を実行する | 🚫 禁止 |
| `.env` / lockfile / `.git/` / エージェント設定を直接書き換える | 🚫 禁止 |
| 契約に反するコミット（複数stage・対象名不一致・日本語なし・AI署名・`--amend`） | 🚫 禁止 |
| `git push` / `git cherry-pick`、依存の install / add | 🚫 禁止 |

エージェント実装上の差分:

| 操作 | Claude Code | Codex |
|---|---|---|
| localhost を含むHTTP request | sandbox外承認 | permission profileのnetwork無効化によりsandbox外承認 |
| `package.json` / CI / migration 等のpath単位確認 | settingsのaskで強制 | rulesのpromptで1回限りの変更tokenを発行 |
| 既存ファイルの全面Write | `overwrite.sh`でask | `apply_patch`は部分差分。opaque shellはrulesでprompt |
| 設定・skillの更新 | sandbox除外済み固定スクリプト | rulesでallowした固定スクリプト |
| MCPの未登録tool | Claudeの既定確認 | `default_tools_approval_mode = "prompt"` |

挙動を決めている実体（想定外の動きをしたらここを見る）:

| 責務 | 実体 |
|---|---|
| Claude Codeの許可 / 確認 / 禁止 | `claude/settings.local.json` |
| Codexのpermission profile / network / MCP承認 / hook有効化 | `codex/config.toml` |
| Codexのcommand単位の許可 / 確認 / 禁止 | `codex/rules/default.rules` |
| Codexのhook eventと実行timeout | `codex/hooks.json` |
| 単一読み取りcommand、stderrの`/dev/null`破棄の安全な除去、複合shell・危険optionの拒否 | `hooks/shell/readonly-search.sh` |
| testの有無によるコード書き込み判定 | `hooks/shell/require-test.sh`。Claude Codeはtddのfrontmatter、Codexは常時配線と`session.sh`のmarkerでtdd中だけ執行 |
| 復元できない全上書きの確認（Claude Code） | `hooks/shell/overwrite.sh` |
| `.claude` / `.codex` / `.agents`の自己改変防止 | `hooks/shell/protect-config.sh` |
| `.env` / `.env.*`の書き込み・削除防止 | `hooks/shell/protect-env.sh`。sandbox / permission profileとの二重層 |
| lockfileの編集tool・Bash直接変更の拒否 | `hooks/shell/protect-locks.sh`。permission設定との二重層 |
| Prisma migrationとDB直接反映commandの拒否 | `hooks/shell/deny-migration.sh` |
| review対象fileの未承認変更拒否と、Codexのpath単位1回限り承認 | `hooks/shell/protect-review.sh` |
| commit契約（stage厳密1件・対象file名一致・日本語・AI署名禁止） | `hooks/shell/commit-gate.sh` |

## テスト

テンプレート自体の回帰テスト。**hook・スキル・配布設定を変更したら必ず実行する。**

```
bash tests/verify-all.sh
```

- `tests/verify-all.sh` — 統合スイート。一時ディレクトリに claude / codex の配置を再現し、`bootstrap` の placeholder 置換・`[NOTE]` 解決を実行したうえで全 hook を検証する。最後に `PASS=n FAIL=0` を出す
- `tests/run-tests.sh` — hook 全数の deny / ask / 棄権テスト（`verify-all.sh` から呼ばれる。単体では動かない）
- 検証範囲: 構文 / 実行ビット / 配置シミュレーション（claude・codex）/ 権限パスマトリクス / MCP version・tool承認 / Codex config strict読込 / execpolicy判定 / commit契約 / hook参照先・timeout / placeholder置換漏れ / hook決定JSON / `session`の発火スコープ / 固定宛先スクリプト / `rebase` E2E
- 前提: `jq` と `git`。Codex CLI があれば 0.138.0 以上であることと config / rules の実機検査を行い、無い環境ではその部分だけskipする
- 作業ファイルは一時ディレクトリに作られ、終了時に削除される。`tests/` 自体は配布対象外
