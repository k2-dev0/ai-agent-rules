# ai-agent-rules

複数の AI コーディングエージェント（Claude Code / Codex 等）に対して、共通の規約・スキル・フックを横断的に適用するためのテンプレート集。

## 目的

エージェントごとに設定ファイルや配置ディレクトリ（`.claude/`, `.codex/` …）が分かれていても、開発上守らせたいルールは同じであることが多い。本リポジトリは次の点を狙う。

- **規約の一元管理**: コーディング規約やパターン集を `AGENTS.md` と `rules/` に集約し、どのエージェントから参照しても同じ振る舞いになるようにする。
- **エージェント間の差分を placeholder で吸収**: テンプレートでは `[agent_name]`（エージェント名）と `[skills_root]`（skills 配置先）を使って書いておき、`bootstrap` スキルで対象エージェントに合わせて実体化する。hook の入出力スキーマ差分は `hooks/shell/hook-io.sh` が吸収する。
- **必要な統制をフックで強制**: 設定・秘密情報の変更防止やコミット契約を実行時に確認する。設計の妥当性と必要なテストは、規約とレビュー工程で判断する。

## 構成

```
ai-agent-rules/
├── AGENTS.md           # エージェントが従う最上位の規約
├── SOURCE_REPOSITORY.md # 配布元だけでsessionへ注入する説明（配布対象外）
├── rules/              # AGENTS.md から分離したパターン別の規約
│   └── typescript/         # TypeScript プロジェクト固有のルール
├── skills/             # スキル（スラッシュコマンド相当）の定義
│   ├── bootstrap/          # placeholder を解決し、成功後に配置先から自己削除
│   ├── meeting/            # 要件監査・設計作成・単純化を統括するユーザー向け入口
│   ├── preflight/          # 要件の由来・既存経路・境界ゼロ案を設計前に調査
│   ├── cowlick/            # 機能ごとの設計書を prompt/ へ直接作成
│   ├── ponytail/           # 全設計書横断で最小代替案と比較し、過剰設計を削除
│   ├── worker/             # 変更済みpathのネスト候補だけを下位モデルで抽出する実行器
│   ├── tdd/                # testシナリオ選択後、テスト・委任実装・レビューを連続実行
│   ├── errand/             # 設計書なしでtestシナリオ選択・Red・委任実装・Greenを実行
│   ├── rebase/             # 1 ファイル = 1 コミット履歴を機能単位に squash
│   ├── polish/             # receipt付き実変更またはdirect明示pathを整形・静的検査・ネスト確認
│   ├── unwind/             # 深い制御フローネストを構造的に縮退
│   ├── dictionary/         # context-dictionary MCPによる知見の検索・保存・更新policy
│   └── e2e/                # chrome-devtools-mcp による E2E テスト
├── hooks/
│   └── shell/              # PreToolUse hook 本体（圧縮した必須契約の注入を含む）
├── prompt/             # 実装順 index（.prompt.md）と設計書の配置先シード（cowlick / tdd が使用）
├── e2e/                # .e2e.md の配置先シード（e2e スキルが使用）
├── claude/             # Claude Code 用の設定（settings、agents、CLAUDE.md 等）
├── codex/              # Codex 用の設定（config、hooks、agents、rules）
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
| `codex/agents/` | `<repo>/.codex/agents/` |
| `codex/rules/default.rules` | `<repo>/.codex/rules/default.rules` |
| `hooks/` | `<repo>/.codex/hooks/` |
| `rules/` | `<repo>/.codex/rules/` |
| `prompt/` | `<repo>/.codex/prompt/` |
| `e2e/` | `<repo>/.codex/e2e/` |
| `skills/` | `<repo>/.agents/skills/` |

配置後は次の順序で有効化する。

1. `setup-agent`で配置する。初回・`--update`とも、context-dictionaryのlocal実pathと`[agent_name]` / `[skills_root]`を自動で解決し、検証後にbootstrapを削除してからエージェントを起動する。起動省略時も初期化までは完了し、初期化失敗時は起動しない。手動配置では`__CONTEXT_DICTIONARY_ROOT__`を実pathへ置換する。
2. Codex の対話セッションを対象リポジトリで開き、project を trusted にする。未信頼では project-local の config / hooks / rules がすべて無視される。
3. **手動配置の場合だけ**`$bootstrap codex`を実行し、placeholderを解決する。成功後、配置先のbootstrap skillは自己削除される。`setup-agent`を使った場合、この操作は不要。
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
| `claude/agents/` | `<repo>/.claude/agents/` |
| `hooks/` | `<repo>/.claude/hooks/` |
| `rules/` | `<repo>/.claude/rules/` |
| `prompt/` | `<repo>/.claude/prompt/` |
| `e2e/` | `<repo>/.claude/e2e/` |
| `skills/` | `<repo>/.claude/skills/` |

`setup-agent`は`claude/.mcp.json`をproject rootへ配置し、`context-dictionary`のlocal実pathを反映する。初回・`--update`ともbootstrapの初期化処理を自動で完了させてから起動するため、スキルの手動実行は不要。配置後にprojectをtrustし、`.mcp.json`のSerenaとcontext-dictionaryを承認する。contextの読み取りtoolだけを自動許可し、書き込みtoolは毎回確認する。

手動配置した場合のbootstrap呼び出し形式:

```
# claude
/bootstrap claude

# codex
$bootstrap codex
```

### 上位モデルの調査と下位モデルの実装・限定QA

役割分担は次で固定する。

| 工程 | 担当 | 境界 |
|---|---|---|
| コードベース探索・根拠収集 | Codex / Claude Code | 上位モデルが直接行う。下位モデルへresearch / surveyを委任しない |
| 設計判断・要件判断・根拠の採否 | Codex / Claude Code | 上位モデルが行う |
| 承認済み範囲の初回実装 | 下位モデルのnative implementer | 要求に必要なproduction codeと`schema.prisma`を変更し、指定済みtestを実行する |
| レビューで見つけた大きい問題の再実装 | 下位モデルのnative implementer | 上位モデルの確定済み指摘だけを修正し、指定済みtestを実行する |
| 3段以上の制御フローネスト候補の抽出 | 外部worker | 上位モデルが確認済みの変更production pathだけを読み取る。変更要否は判断しない |
| 差分・QA候補の採否、大小判定、小修正、テスト、最終レビュー、Git | Codex / Claude Code | 上位モデルが行う。大きい問題は修正briefを下位モデルへ戻す |

共通契約は`skills/`直下に置き、各スキルとagent定義から参照する。同じ判断基準を各フローへ書き写さず、次の正本を更新する。

| 正本 | 管理する内容 |
|---|---|
| [IMPLEMENTATION_RULES.md](skills/IMPLEMENTATION_RULES.md) | 設計・実装・レビューの共通判断と、言語別規約への入口 |
| [IMPLEMENTER_CONTRACT.md](skills/IMPLEMENTER_CONTRACT.md) | Claude / Codexの実装役が行う作業、変更境界、検証・報告 |
| [IMPLEMENTER_LAUNCH.md](skills/IMPLEMENTER_LAUNCH.md) | 親から専用実装役を呼び出す際のAPI指定・待機・識別方法 |
| [SCENARIO_FLOW.md](skills/SCENARIO_FLOW.md) | tdd / errandの調査、シナリオ選択、Red、委譲、Greenの順序 |
| [REVIEW_FLOW.md](skills/REVIEW_FLOW.md) | 差分検証、診断の帰属、修正担当の判定、再実装・最終レビュー |

`tdd`は設計書の選択とpolish・完了処理、`errand`は依頼の適用範囲と限定検証を追加する。設計書の記法・必須情報・圧縮範囲は[cowlickの設計書形式](skills/cowlick/DESIGN_FORMAT.md)で管理する。agent定義にはモデル・ツールと共有契約の読み込み指示を残し、読み取りtoolの違いは各製品の定義で扱う。

`meeting`、`preflight`、`cowlick`、`ponytail`のコードベース調査も上位モデルが直接行う。`ponytail`は同じ会話内で設計書を読み直すため、過去の文脈が隔離されるとは主張しない。preflight / cowlickの結論を根拠として流用せず、現在の`.prompt.md`と参照設計書を要件契約とし、適用規約と既存実装を再確認する。設計書だけでは目的、対象機能、要求、Changes、完了条件を特定できない場合は、過去の文脈で補完せず`blocked`とする。

外部workerは`delegate.sh nesting`による限定QAだけに使う。対象は上位モデルが先に確定した変更production pathであり、workerの役割は3段以上の制御フローネスト候補と位置の抽出までとする。修正要否、設計との整合、誤検出、修正、再テストは上位モデルが判断する。`delegate.sh research`と`delegate.sh survey`は入口で拒否する。

`delegate.sh`の`prepare`、`smoke`、`show`は実行器の運用modeであり、調査委任ではない。pollはprocess、出力byte、有効JSON eventを観測し、前回より増えた有効eventだけでidleを更新する。推測的な意味判定は実ログで安全性を確認するまでkill条件へ使わない。

timeout時はprocess groupへTERMを送り、10秒後も残るprocessだけをKILLする。途中tool出力から結論を生成せず、生の`opencode.jsonl`と最終回答がある場合だけそのreportをpublishする。`smoke`だけは固定疎通確認なので30秒無通信・1分総時間・5秒間隔を使う。

task-idごとに原子的な実行lockと状態metadataを作り、同じtask-idの重複起動を拒否する。親実行器が中断された場合はmonitorとOpenCode process groupを終了し、`show`へ`interrupted`を残す。`show`は未開始、`running`、`orphaned-running`、`interrupted`、失敗、完了を区別するため、実行中の結果有無を`find`や`ps`で推測しない。

`errand`は対象ファイルが未実装、複数、または対応テストが未作成であることだけでは停止しない。同じ既存パターンから変更を一意に決められる本体コードと`schema.prisma`を許可できる。公開挙動を一意に決められるならテストシナリオ候補を提示し、ユーザーが選択したものだけをテストへ変換してRedから実装へ進む。ただし設定、migration file、依存関係は対象外であり、`prisma migrate`・`prisma db push`・`prisma db execute`は全workflowでhookが拒否する。

事前にOpenCodeをインストールし、専用のOpenRouter API keyを環境変数へ設定する。

```bash
export OPENROUTER_API_KEY="..."
```

API keyには40 USD以下の月次またはリセットなしhard limitを設定する。固定実行器は使用量38 USDで新規実行を止め、各リクエストでもZDRと学習利用拒否を強制する。キーはリポジトリへ保存しない。

疎通確認は`bash [skills_root]/worker/delegate.sh smoke`で固定promptの`hello`だけを送る。従量課金のため通常テストでは実行せず、デフォルトはスキップする。実行前にユーザーへ確認する。

通常はスクリプトを直接操作せず、`unwind`または`polish`のネストQA手順から呼ぶ。実行器はHEADから指定された本体コードだけを一時snapshotへ複製して読み取り専用にし、テスト、設計、設定、Git、外部plugin、任意shellを外部workerへ許可しない。

限定snapshotは現在のHEADを基準にし、指定された変更path以外を物理的に持ち込まない。無視されたagent資料、`.codex/tmp`、`.git/**`、`.env`系も含まれない。編集権限は与えず、実行後にファイル数とblob hashを検査する。OpenCodeのdata・state・cache・config・tmp領域もtaskごとの一時directoryへ分離し、並列worker間でSQLiteを共有しない。

既存配置へ更新するときは、ユーザーが編集した設定・設計書を先に比較する。新しいファイルを上書きコピーするだけでは削除済みファイルは消えない。旧`require-test.sh`とその登録、旧bootstrapの`[NOTE]`処理を残さず、今回の設定・hook・skillを整合する版で配置する。配布先の`AGENTS.override.md`の有無も確認する。外部の`setup-agent`実装による更新・削除処理は、このリポジトリのテスト対象に含まれない。

## 規約を実際の作業へ適用する

明示起動用のskillは、Claudeの`disable-model-invocation`に加え、Codex用の`agents/openai.yaml`で`allow_implicit_invocation: false`を設定する。両者を同じ設定と見なさない。Codex側の根拠は[skillの起動policy](https://learn.chatgpt.com/docs/build-skills#optional-metadata)。

AGENTS.mdは全行動へ共通する短い指示だけにする。配置・命名・インライン化などの判断基準は`skills/IMPLEMENTATION_RULES.md`へ置き、設計・実装・レビューskillが必要時に読む。TypeScript/JavaScript/Prismaの初回編集では、既存の`load-required-contract.sh`がこの資料を一度注入して編集を止め、規約を反映した再試行へ進める。秘密情報・設定・lockfile等の操作禁止は専用hookが強制し、AGENTSへの注意書きで代用しない。

実装役の呼び出し方は[IMPLEMENTER_LAUNCH.md](skills/IMPLEMENTER_LAUNCH.md)へ集約する。`require-implementer.sh`はTDD/errand中の誤ったroleに加え、専用implementerへのモデル・effort上書き、専用定義の不整合、共通契約の欠落を起動前に拒否する。Codexはfresh contextの明示も検査する。設定検査をhookへ統合したため、旧`skills/tdd/preflight-implementer.sh`は配布先から削除する。

Huygens等はUI用のnicknameで、roleとは別である。実際のログでもHuygensのroleはimplementer、Luna/maxだった。親のread-onlyが継承されていたことが承認増加に直結する。専用定義のworkspace-writeが親の実行時権限を解除するとは考えない。hookで分かるplan/read-onlyでは起動を止め、親側で権限を一度確認する。nicknameを変える目的でagentを再起動しない。根拠は[Codexのsubagent仕様](https://learn.chatgpt.com/docs/agent-configuration/subagents#approvals-and-sandbox-controls)。hookは起動後のSubagentStartでは停止できないため、起動前のPreToolUse（Agent）で検査する。[hookの対応範囲](https://learn.chatgpt.com/docs/hooks#tool-coverage)。

`polish`のpath完全性検査には全対象を渡すが、ネストQAはその中の本体コードだけを使う。文書・設定・Prisma schemaだけなら外部workerを省略する。同じHEADの再検査でもworkerのtask-idを分け、前回の結果を上書きしない。

今回の全体監査の修正内容・削除判断・残る代替候補は[AUDIT.md](AUDIT.md)に記録する。監査記録は配布対象ではない。

## 注意

- `SOURCE_REPOSITORY.md` は配布元でだけ使う。localの`.claude/`・`.codex/`から読み込み、`setup-agent`は配置先へコピーしない。
- 本リポジトリはテンプレートなので、`bootstrap` 実行時にここのファイルを書き換えてはいけない。コピー先で置換する。
- placeholder の dot は placeholder の外側に置く規約（例: `.[agent_name]/...`）。置換漏れ検証は `init-agent.sh` 内で完結させる。
- Claude Code は `AGENTS.md` を自動読み込みしない（`CLAUDE.md` のみ）。そのため `claude/CLAUDE.md`（中身は `@AGENTS.md`）を配置時にプロジェクトルートへ展開して読ませる。codex は `AGENTS.md` を直読みするため不要。
- Codex は `distributed` permission profile で通常の workspace 書き込みを許可する。`.claude` / `.codex` / `.agents` の設定・skillはhookで保護するが、設計書の正本である `.[agent_name]/prompt/` はユーザーとエージェントが直接編集できる。レビュー対象パスは、配布rulesが毎回確認する承認コマンドと1回限りのhook tokenで保護する。設定更新は限定allowした固定スクリプトだけを使い、汎用の `cp` / `sed` に例外を与えない。
- Codex の hook は**配置しただけでは実行されない**。`/hooks` で現在の定義をレビューして信頼すること。未信頼のhookはスキップされる（検証用の一時迂回フラグは `--dangerously-bypass-hook-trust`）。

## 承認の挙動

新規作成とmetadata変更は、workspace sandbox内で自動実行する。shellによる既存ファイルの内容変更は、変更差分を確認できないため禁止する。削除、保護対象への変更、外部通信は、それぞれの確認・禁止規約に従う。

通常ファイルと `.[agent_name]/prompt/` の内容変更は、差分が見える Edit / `apply_patch`を使う。shellでコピーする場合は `cp -n -- SOURCE DEST` とし、既存の宛先を上書きしない。新しいテキストの作成はWriteを使える。`>`・`>>`による通常ファイルへの出力は、新規かどうかを実行前の存在確認だけでは保証できないため拒否する（`/dev/null`への出力は除く）。

このhookが検査するのは直接呼び出したshell commandであり、任意のスクリプト内部の全副作用を証明する仕組みではない。テスト・formatter・配布用の固定スクリプトは、従来どおりレビューされた実行入口を使う。上書きを隠すために別スクリプトを作って迂回してはいけない。

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
| 単一のAWS CLI commandで`--profile daresuma-readonly`または`--profile=daresuma-readonly`を明示する | ✅ service / actionを限定せず自動 |
| `package.json` / CI / migration file / Docker / Terraform を書き換える | 🙋 確認 |
| `schema.prisma`を書き換え、`prisma format` / `validate` / `generate`を実行する | ✅ 自動 |
| shellで新規作成する（`touch`、`cp -n -- SOURCE DEST`、`ln [-s] -- SOURCE DEST`） | ✅ 自動。既存の宛先は置換しない |
| metadataを変更する（`touch` `chmod` `chown` `chgrp`） | ✅ 自動 |
| shellで内容を変更する（上書き可能な`cp`・`mv`、`sed -i`、`tee`、`>`・`>>`等） | 🚫 拒否。承認では解除せずEdit / `apply_patch`を使う |
| ファイルを消す（`rm`等） | 🙋 確認 |
| localhost を含むサーバーへ HTTP request を送る | 🙋 sandbox 外で確認 |
| `commit-subject.sh` が生成・検証する契約に従うコミット | ✅ 自動 |
| TDD / errandでRed確認前にnative implementerを起動する | 🚫 workflowで禁止 |
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
| `package.json` / CI / migration 等のpath単位確認 | settingsとEdit / Write / NotebookEditのhookでask | rulesのpromptで1回限りの変更tokenを発行 |
| 既存ファイルの全面Write | `overwrite.sh`でask | `apply_patch`で差分編集 |
| 設定・skillの更新 | sandbox除外済み固定スクリプト | rulesでallowした固定スクリプト |
| local ESLint（`yarn eslint`） | 既定確認 | rulesの固定prefixで自動 |
| MCPの未登録tool | Claudeの既定確認 | `default_tools_approval_mode = "prompt"` |

挙動を決めている実体（想定外の動きをしたらここを見る）:

| 責務 | 実体 |
|---|---|
| Claude Codeの許可 / 確認 / 禁止 | `claude/settings.local.json` |
| Codexのpermission profile / network / MCP承認 / hook有効化 | `codex/config.toml` |
| Codexのcommand単位の許可 / 確認 / 禁止 | `codex/rules/default.rules` |
| Codexのhook eventと実行timeout | `codex/hooks.json` |
| 単一読み取りcommand、`daresuma-readonly`を明示したAWS CLI、stderrの`/dev/null`破棄の安全な除去、複合shell・危険optionの拒否 | `hooks/shell/readonly-search.sh` |
| shellの内容変更・redirectを拒否し、コピー・移動にno-clobberを要求する | `hooks/shell/shell-file-write.sh`。`sed`は行抽出だけを許可 |
| TDD / errandの上位モデル直接調査・レビューと下位モデル初回実装・再実装 | `skills/SCENARIO_FLOW.md`、`skills/REVIEW_FLOW.md`、`claude/agents/implementer.md`、`codex/agents/implementer.toml` |
| 変更production pathのネスト候補抽出 | `skills/worker/delegate.sh nesting`と`skills/{unwind,polish}/SKILL.md`。候補の採否は上位モデルが行う |
| 実装前baselineとpolish対象の自動列挙 | `skills/polish/capture-scope.sh <機能名> --auto`と`list-changed`。書き込み認可には使わない |
| polishのpath検査 | `quality-gate.sh <機能名> -- <実変更path>...`はreceiptと完全一致を検証するverified mode。`--direct-check` / `--direct`は通常の直接修正で明示pathだけを検査し、完全性を`scope-unverified`とする |
| 復元できない全上書きの確認（Claude Code） | `hooks/shell/overwrite.sh` |
| `.claude` / `.codex` / `.agents`の設定・skill自己改変防止（`prompt/`は直接編集可） | `hooks/shell/protect-config.sh` |
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

- `tests/verify-all.sh` — 統合スイート。一時ディレクトリに claude / codex の配置を再現し、`bootstrap` の placeholder 置換を実行したうえで全 hook を検証する。最後に `PASS=n FAIL=0` を出す
- `tests/verify-regressions.sh` — 空白入り配置先での実hook配線、必要時の規約注入、専用agent選択と親権限、親symlink、履歴整理中の並行編集・commit、workerの無通信判定を検証する
- `tests/run-tests.sh` — hook 全数の deny / ask / 棄権テスト（`verify-all.sh` から呼ばれる。単体では動かない）
- 検証範囲: 構文 / 実行ビット / 配置シミュレーション（claude・codex）/ 権限パスマトリクス / MCP version・tool承認 / Codex config strict読込 / execpolicy判定 / commit契約 / hook参照先・timeout / placeholder置換漏れ / hook決定JSON / `session`の発火スコープ / 固定宛先スクリプト / `rebase` E2E
- 前提: `jq` と `git`。Codex CLI があれば 0.138.0 以上であることと config / rules の実機検査を行い、無い環境ではその部分だけskipする
- skill形式検査は`SKILL_VALIDATOR`または標準配置のvalidatorがある場合だけ実行する。個人の絶対pathは前提にしない
- 作業ファイルは一時ディレクトリに作られ、終了時に削除される。`tests/` 自体は配布対象外
