# 全体監査記録 — 2026-09-06

配布元の指示・規約・実行スクリプト・検証を走査し、24項目を修正した。不要な旧フックと専用の初期化処理は削除した。追加の改善・代替候補は後半へ分離した。

## 範囲と読み方

- 開始時のcommitは`d21eea1`。追跡対象71ファイルを棚卸しし、全文、参照先、設定への登録、呼び出し元を確認した。対象は共通文書、Claude/Codex設定、全hook、TypeScript規約7枚、skill12個と補助スクリプト、テスト、配布用の空のindex。
- `.git/info/exclude`、無視された`AGENTS.override.md`、ローカルの`.claude/`・`.codex/`・旧作業メモも、現在の設定との差を調べた。Git内部のobject、Serenaの生成キャッシュ、`.DS_Store`はコードレビュー対象外。
- 自分の設定として`~/.codex/AGENTS.md`、`~/.codex/config.toml`の関連設定、このリポジトリのローカル設定を確認した。認証情報は報告へ転記していない。
- 引用された別リポジトリ`daresuma-2024-07-batch-v2`は、原因説明に関係するAGENTS、規約、implementer、設計書、依存関係、XMLメール関連コードだけを参照した。別リポジトリ全体の監査・修正・再配布は実施していない。
- P1は内容の消失・保護対象の変更に関わる問題、P2は誤動作・規約不整合・検証不足、P3は保守性や説明の改善。列挙は今回確認できた事項であり、未発見の問題が存在しないという保証ではない。

## 修正済み事項

| ID | 優先度 | 修正前の事実と影響 | 修正・根拠となるファイル |
|---|---|---|---|
| F01 | P2 | 規約が独立したMarkdownとして置かれ、必要な作業で読み込む導線がなかった | AGENTS.mdは元の2行を維持。[skills/IMPLEMENTATION_RULES.md](skills/IMPLEMENTATION_RULES.md)から対象別規約へ案内。設計・実装・レビューskillから参照し、対象コード初回編集時は既存hookが資料を一度注入する |
| F02 | P2 | 共通フローがtask名implementerとLuna/maxの指定に依存し、専用role選択を明記していなかった | [SCENARIO_FLOW.md](skills/tdd/SCENARIO_FLOW.md)でCodexのagent_type、Claudeのsubagent_typeにimplementerを指定。[require-implementer.sh](hooks/shell/require-implementer.sh)でTDD/errand中の汎用agent起動を拒否。指示本文コピーによる代用も廃止 |
| F03 | P2 | 一度しか使わない関数を例外なく禁止する一方、複数使用ならutils.ts、5行以上のJSXならcomponentという機械的分割を要求していた | [function-pattern.md](rules/typescript/function-pattern.md)、[ui-pattern.md](rules/typescript/ui-pattern.md)を実際の利用箇所・責務・インライン案との比較へ変更 |
| F04 | P2 | yup、modules内のutility、dayjs入口、@frontのpathなどを実在確認なしに要求していた | [validation-pattern.md](rules/typescript/validation-pattern.md)、[date-pattern.md](rules/typescript/date-pattern.md)、UI規約で、対象packageの依存・export・既存例を確認するよう変更。規約だけを理由に依存やwrapperを追加しない |
| F05 | P2 | 過剰実装を避ける一般指示はあったが、テスト用Client注入、内部値の重複防御、ファイル名とexportの不一致を採否へ結び付けていなかった | 両[implementer](codex/agents/implementer.toml)と共通実装・レビュー工程へ、外部境界と内部保証の区別、実際のconsumer、配置・命名の既存例を追加。構造とテストを別判定 |
| F06 | P2 | 設計書のファイル構成やmock可能性を、そのまま不変の要件へ昇格させやすかった | [DESIGN_FORMAT.md](skills/cowlick/DESIGN_FORMAT.md)に設計根拠を追加。ユーザーの要求と変更可能な実装手段を区別し、既存構成に合わせた調整を許容 |
| F07 | P2 | ponytailは同じ会話内で動くのに事前知識がないと規定。全要素に外部consumerを要求するため、正当なlocal helperにも不要なexportを作る圧力があった | [ponytail](skills/ponytail/SKILL.md)と[meeting](skills/meeting/SKILL.md)を再調査・証拠の再確認と表現。同一fileのconsumerも認め、切り出し理由で評価 |
| F08 | P2 | テスト規約が正常系を一律禁止し、実装フローの正常系選択と矛盾。廃止済みrequest validatorも要求していた | [tdd-pattern.md](rules/typescript/tdd-pattern.md)で要求の欠落・回帰を検出するケースを選ぶ方式へ統一。実装briefへ正確なtest pathとcommandを渡す |
| F09 | P2 | 単一書き込みにもtransaction、固定降順の要求にもsort引数やUI reverseを増やす規約だった | [api-pattern.md](rules/typescript/api-pattern.md)を必要な原子性と利用者の要求へ限定 |
| F10 | P2 | DecimalをFloatと同じ丸め誤差の理由で禁止。camelCase規約とsync_atの例も矛盾。多対多の明示modelを将来性だけで必須化 | [db-pattern.md](rules/typescript/db-pattern.md)で必要精度・単位・mappingと実際の関係属性に基づく方式へ訂正。provider固有型の適用範囲も明示 |
| F11 | P1 | Claudeの構造化編集にprotect-configが未接続で、Writeによる新しいpackage.json等もreview hookの対象外。逆にEdit(.claude/**)は禁止例外のpromptまで止めていた | [settings.json](claude/settings.json)でEdit/Write/NotebookEditへ両hookを接続し、reviewはaskへ。prompt例外と衝突する広いdenyを除去。実際の登録commandで検証 |
| F12 | P2 | Claudeのhook commandでproject pathを引用しておらず、空白入りディレクトリで起動できない | settings.jsonのproject pathを引用。空白入り配置先でbootstrapと登録hookを実行 |
| F13 | P2 | overwrite hookが親directoryへ移動した後も元の相対pathでGitを検索し、追跡済みの正常fileを誤判定。[]等はpathspecにも解釈された | [overwrite.sh](hooks/shell/overwrite.sh)をbasenameのliteral pathspecへ変更。追跡済みclean/dirty双方を検証 |
| F14 | P1 | promptへの書き込み例外がprompt/../settings.jsonにも一致した | [protect-config.sh](hooks/shell/protect-config.sh)で親参照を含む例外を拒否する回帰テストを追加 |
| F15 | P1 | e2e計画、設計完了index、polish直接指定が親directoryのsymlinkを経由できた | [apply-e2e-plan.sh](skills/e2e/apply-e2e-plan.sh)、[mark-prompt-done.sh](skills/tdd/mark-prompt-done.sh)、[quality-gate.sh](skills/polish/quality-gate.sh)で親リンクを拒否。外側の内容が保持されることを確認。directのcolon・非正規path・通常file判定も訂正 |
| F16 | P1 | rebaseは開始時のclean確認後、最終reset --hardまでに追加された編集・stage・commitを消せた | [rebase.sh](skills/rebase/rebase.sh)を旧HEAD照合付きupdate-refへ変更。同一treeのrefだけを更新し、並行編集とindexを保持。並行commit時は上書きせず失敗 |
| F17 | P2 | workerはログに過去の正常JSONが一つあるだけで、その後のごみ出力でもidle時計を更新。予算照会にも総時間制限がなかった | [delegate.sh](skills/worker/delegate.sh)で有効eventの増加だけを活動と判定。予算照会に接続・総時間制限を追加。正常event後にごみを出し続けてもidle停止することを検証 |
| F18 | P2 | workerは本体コードだけという契約なのに、agent設定directory内の.ts/.shやvendor等も拡張子で通せた | delegate.shで設定・依存・生成directoryを対象外として実行前に拒否 |
| F19 | P2 | polishは全変更pathをそのままnestingへ渡すため、文書・test・Prisma schemaが混ざるとworkerが失敗。同じHEADの再実行は固定task-idで衝突 | [polish](skills/polish/SKILL.md)でネスト検査だけ本体コードへ選別。scope検査は元の全件を維持。[unwind](skills/unwind/SKILL.md)で実行ごとに異なるtask-idを使用。Biome optionも導入版のhelpから選ぶ |
| F20 | P3 | require-test.shはどちらの配布設定にも未接続で、廃止済みimplementation.active/request.jsonへ依存。専用NOTE置換も不要だった | 旧hook112行と[bootstrap](skills/bootstrap/init-agent.sh)のNOTE変換を削除。実際には何もしないBashの資料注入hook登録も除去。tdd/errand markerは新しい専用agent guardの消費者があるため維持 |
| F21 | P2 | 「Codex CLIなしならskip」と説明しながらMCP検証が無条件でCLIを実行。skill validatorは個人の絶対path固定 | [verify-context-mcp.sh](tests/verify-context-mcp.sh)でCLI検査のみ条件化。[verify-all.sh](tests/verify-all.sh)でvalidatorを標準配置または明示pathから任意利用。CLIのないPATHでも検証成功 |
| F22 | P2 | READMEは削除済み工程や実現していない履歴隔離を説明。既存テストは文言の存在やhook単体の成功に偏り、配線不備を捕捉していなかった | READMEを現行工程へ同期。[verify-regressions.sh](tests/verify-regressions.sh)で実登録command、配布後の参照、並行変更、symlink、idleを検証 |
| F23 | P2 | 明示起動skill7個のうち、Codexのallow_implicit_invocation:falseがあるのはerrandだけ。Claude用frontmatterとCodexの起動policyが未同期 | bootstrap/meeting/tdd/polish/rebase/e2eのagents/openai.yamlへCodex用policyを追加。配布後のpolicy存在も検証。モデルの自動選択を実際の対話で評価したものではない |
| F24 | P2 | Huygensは別roleではなくimplementerだった。親のread-onlyが子にも継承され、専用定義のworkspace-writeでは解除されなかった | 起動前hookでplanと、Codex transcriptから確認できるread-onlyを拒否。skillで親の実効権限を起動条件とし、roleを先に報告。既存の他タスクやglobal権限は変更していない |

Codexは同一階層のAGENTS.override.mdをAGENTS.mdより優先し、任意のrules/*.mdを置くことは読み込み指示の代わりにならない。[公式の指示読み込み仕様](https://learn.chatgpt.com/docs/agent-configuration/agents-md)。明示起動のCodex側の根拠は[skillの起動policy](https://learn.chatgpt.com/docs/build-skills#optional-metadata)。MySQLのDecimalは固定小数点の正確値型であり、Floatと同一の理由で排除しない。ただし必要なscaleを超える値の丸めまでなくなるわけではない。[MySQLの数値型仕様](https://dev.mysql.com/doc/refman/8.4/en/precision-math-numbers.html)。

## 提示された原因説明への判断

主因は、既存の過剰実装防止指示を実際の設計と差分の採否へ適用できなかったこと。ただし「禁止指示が既にあった」で設定側の問題を終えるのも不正確だった。

1. **規約へ到達しない。** 必要なskill・hookから規約へ到達する導線がなく、ファイルを置いただけで適用されるように扱っていた。AGENTSを肥大化させる解決は採らず、必要時の読み込みへ変えた。テンプレートのtask名指定も専用role選択へ改めた。ファイルが存在することと、実行時に読み込まれたことは別。
2. **規約が逆方向へ誘導する。** 一度しか使わない関数の無条件禁止と、行数によるUI分割が共存。実在しないutilityや古い依存の指定、外部consumerの必須化、将来用の中間modelが、不要な構造を追加する圧力になっていた。
3. **設計書の案を要求へ昇格させる。** mock可能性、service/schemaという一般名、初期の分割案を優先し、実際の利用箇所・export・配置の意味と比較していなかった。
4. **動作検証で構造レビューを代用する。** テストが通ることは、ClientLike、helper、file分割、二重のguardが必要である証拠にならない。今回の初期テストも成功したまま複数の実不具合が残っていた。

自分のglobal設定にはgpt-6-astra、xhigh、read-only、on-requestが記録されていた。一方、このタスクの実効権限はworkspace書き込みを許可している。設定ファイルの一値だけで実効権限や挙動を説明しない。global AGENTSは話し方とHTTP規約が中心で、プロジェクトの配置・命名判断を代替しない。

この配布元のローカル.codexには旧ルール名が残り、現行の.codex/hooks.jsonや.agents/skillsはなかった。ローカル.claudeにも旧規約・旧skill・旧hook登録が残っている。今回の配布物がそのまま自分の実行設定だった、とは判断できない。この混同を避けるため、無視されたAGENTS.override.mdから配布元のSOURCE_REPOSITORY.mdを短く参照させた。行動理念はskills、操作を拒否する規約はhookに置き、AGENTSへ増設しない。

引用元の別リポジトリでは、確認時点のfront/package.jsonはZodを依存に持ち、XMLメールのschema.tsも既にZod schemaをexportしていた。一方、xml-mail-client.tsにはClientLike型とClient引数が残っていた。過去の「schema.tsが手書き検証関数だった」という状態まで今回再現したものではない。XMLメール対応の過去の実行にどの指示が注入されたか、どのモデルがどの判断をしたかは、この調査からは確定しない。下位モデルの能力だけへ原因を帰属させる根拠もない。

## Huygensとimplementerの確認結果

2026-09-06の保存ログを照合した。子task `01a0733a-bd48-7cc2-9b96-f31c2b693d38`のmetadataは`agent_nickname: Huygens`、`agent_role: implementer`。turn contextは`gpt-5.6-luna`、`max`、`read-only`、`on-request`だった。親task `01a07314-5082-73f3-830b-aef11db5332e`もread-onlyで、起動toolは既に`agent_type: implementer`、`fork_context: false`を指定していた。

したがって、この例を「汎用agentを誤選択したせい」とは説明できない。承認が増える原因として直接確認できたのは親のread-only継承であり、nickname変更で解決しない。インストール済みCodex 0.153.4から生成したprotocol schemaもagentNicknameをランダムな表示名、agentRoleをroleとして別fieldにしている。今後はroleを先に報告する。Huygensという表示名自体を消せる未確認設定は追加していない。

[公式仕様](https://learn.chatgpt.com/docs/agent-configuration/subagents#approvals-and-sandbox-controls)でも親の実行時権限が再適用される。専用定義のworkspace-writeやapproval_policyを変更しても、親のread-onlyを必ず上書きできるわけではない。今回のhookは確認できるplan/read-onlyを起動前に止める。transcriptが無い環境などでは全権限を判定できないため、skillでも親の実効権限を確認する。既存taskの権限変更を完了したという意味ではない。

## 不要・代替可能な部分と残る改善候補

以下は修正済みの不具合とは分ける。方針変更・外部配布・実測を要するため、今回の修正へ機械的に取り込まなかった。

| ID | 対象・判定 | 根拠と次の最小手段 |
|---|---|---|
| R01 | 外部workerは置換候補 | nesting抽出だけにdelegate.sh約730行、OpenCode/OpenRouter、API key、予算照会、timeout、process group、snapshot、成果物管理が必要。既存linterの深さ検査と親のレビューで候補抽出を満たせるなら、この運用一式を削除できる。else-if、callback、実行経路の数え方を既存fixtureと比較してから決める。別の汎用workerは新設しない |
| R02 | 古いローカルコピーと別repoへの配布は更新対象 | 配布元の修正だけでは既設の.claude/.codexは更新されない。ユーザー差分を比較して整合した版へ再配置する必要がある。setup-agentの実装はこのrepoに存在しないため、上書き時に旧hookが削除される保証は今回得ていない。更新時の注意をREADMEへ追記 |
| R03 | native implementerの「指示」と「実行権限」は別管理 | shellを指定testだけに使うのは指示本文の制約。Bash自体やworkspace-writeからGit等の能力が消えるわけではない。preflightの文字列検査でruntimeのtool権限までは証明できない。新しい制御層を増設するより、実際の起動結果・適用指示・権限の確認を導入時に行う |
| R04 | 行数で決まる再委任は簡素化候補 | REVIEW_FLOWは11行以上・2file以上・1行の条件変更でも下位モデルへ戻す。変更が一意でも再brief・再起動・再レビューが増える。委任の費用や修正品質を測り、責務と不確実性による判断へ置換可能。既存の役割分担方針なので今回は変更しない |
| R05 | テストの文言照合は縮小候補 | verify-all.shは約990行で、自然文の完全一致検査が多い。意図を保つ言い換えで失敗し、文言が残れば配線不備を見逃す。実際の設定値・登録command・入力と出力の検査へ順次置換する。今回は発見した実不具合の経路を追加済み |
| R06 | 調査と成果物の重複は統合候補 | preflight/cowlick/ponytail/meetingでrequirements、topology、新設要素、代替案の確認が重なる。意図的な再監査は残し、同一revisionの同じ事実を何度も書かせる部分は一つの設計根拠へ集約できる。全工程の削除は目的が異なるため不適切 |
| R07 | 汎用配布物内の特定project前提は適用範囲の整理候補 | daresuma-readonly、base/scripts/run-unit.sh、Yarn前提、Prismaの主キー・状態tableの方針が共通設定に残る。対象projectへ配るoverlayへ分けるか、導入時に既存値へ合わせる余地がある。認可prefixは既存の承認境界なので、汎用化を口実に広げない |
| R08 | workerのfilenameによるtest判定は改善候補 | *mock*、*stub*、*fake*を含む本体fileも拒否する。現在は漏出防止側へ倒しているが、実projectで正当な本体fileを止めた場合は、既存test配置と明示カテゴリへ判定を狭める。推測だけで例外を増やさない |
| R09 | hookとskillの命令だけで完全な隔離とは主張しない | hookは認識するtool・path・commandを検査する。汎用shellの意味、任意の既存scriptの副作用、native appが読み込んだ設定すべてを静的に証明してはいない。permission、hookの信頼状態、専用agentの指示を分けて扱う |

削除しなかったものにも理由がある。hook-ioは複数hookが使う実際のadapter、capture-scopeは実変更pathの完全性に利用されるreceipt、protect-reviewはCodexの一回限りのpath承認に必要な入口であり、単一使用の薄いwrapperとは異なる。親による独立したGreenも、下位モデルの自己申告だけを採用しない目的がある。新しいスキルや汎用policyエンジンは追加していない。

## 検証結果と限界

- 修正前: 統合`PASS=294 FAIL=0`、hook内訳`PASS=70 FAIL=0`。この状態で配線・履歴競合・idle判定の問題が残っていた。
- 修正後: 統合`PASS=277 FAIL=0`、hook内訳`PASS=63 FAIL=0`。削除した旧hookとNOTE処理のテストを整理したため件数は減少。新しい動作回帰群を統合スイートから実行している。
- Claude/Codexの両配置・placeholder置換・空白入りpath・hook決定JSON・固定宛先・Git履歴整理・Codex strict config・execpolicyを検証した。追加で専用role選択、親のplan/read-onlyとworkspace-writeの区別、必要時の資料注入を検証した。
- Codex CLIを含まないPATHでもMCPテンプレート検証は成功し、CLI固有検査だけskipした。
- 全12 skillと8個のagents/openai.yamlはYAMLとして解釈でき、7個の明示起動policyが一致する。汎用quick_validateはunwindで成功。最初に調べた変更skill6個は、Claude拡張のhooks/user-invocable/disable-model-invocationを未対応キーとして拒否した。後から追加したtdd/errandのAgent hookもこの汎用validatorの対象外。これは解消済みのvalidator成功とは数えていない。共通テンプレートからClaude機能を削るための理由にはしない。
- 外部LLMへの課金呼び出し、実DB、配布先アプリの動作検証は実行していない。外部workerは代替実行器と短時間の実process監視で検証した。静的な指示改善が今後の全回答を保証するとは主張しない。
- 配布物とテストは1ファイル1コミットで記録する。ローカルoverrideの改善はGit対象外。監査記録自体も配布対象外である。
