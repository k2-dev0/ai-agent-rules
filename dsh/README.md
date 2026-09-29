# DSH main profile bundle

DeepSeek Harnessを主実行系にし、外部modelをdirect user messageの明示指定だけで起動するbundle。DSH `0.1.7-rc.2`へ固定している。

## 実効route

| 入口 | Provider / model id | Effort | output上限 |
|---|---|---|---|
| 通常 | `deepseek-official` / `deepseek-flash` | provider既定 | 外部委譲なし |
| `/external-plan` | `zai` / `glm-5.3` | `max` | 12K |
| `/opus-plan` | `anthropic` / `claude-opus-5-5` | `high` | 12K |
| `/external-code` | `zai` / `glm-5.3-code` | `high` | 16K |
| `/review` | `openai` / `gpt-6-sol` | `high` | 8K |

`glm-5.3`と`glm-5.3-code`は同じ上流modelにつけた別id。policyはagentのroleを`provider`/`model`の組から解決するため、plannerとcoderは別idでなければならない。同じ組にすると後から書いた側のroleが解決不能になり、そのrole向けのguardが「許可すべき仕事を拒否する」状態になる。`test/route-identity.test.js`が両者の一致と組の重複不在を強制する。

`claude-opus-5-5`は導入済みpi-ai（`0.85.1`）のcatalogに未収録で、catalogは`claude-opus-5`で止まっている。そのためmodel entry自身が`compat.forceAdaptiveThinking: true`を宣言する。宣言が無いとpi-aiはbudget方式のthinkingを送り、adaptive方式だけを受けるOpus 5.5は出力前に拒否する（課金0、呼出側には`subagent run failed`としか見えない）。`test/route-declarations.test.js`が宣言を固定し、起動時の`assertRouteDeclarations`が欠落を検知してprofile起動を止める。

routeに**step数の上限は無い**。`maxSteps`は、設計routeがtaskの名指ししたfileとそれが参照するfileを読む前に、reviewがfindingsを組み立てる途中で子agentをcancelしていた。step数は調査対象の大きさを知らないので上限として成立しない。costを縛るのは各tool rowの`maxTokens`（output token数）で、これは回答の大きさに対する制約である。`test/hook-responsibilities.test.js`がroute tableへ`maxSteps`が戻らないことを固定する。

routeの回数上限も**無い**。1つのrouting intentは、そのroute toolを何度でも起動できる。失敗したrun、結果を返さなかったrun、同じ作業の続きはcommandを打ち直さずに再実行できる。

## routing intentの生存期間

intentを終わらせるのは**taskについての事実**だけで、turnやcallではない。

| 終わらせる | 終わらせない |
|---|---|
| 同じsessionへの新しいcommand（`superseded-by-command`） | turnの終了（正常終了・中断のどちらでも） |
| agentのdispose | callの成功・失敗・結果なし |
| DSH再起動（open intentは`restart`で閉じる） | 時間経過 |

turnで終わらせない理由は実害が出たためである。`/external-plan`が配送されたturnでmodelがrouteを起動せず、そのturnが中断されると、許可は失われ、以降のturnでは「既に終了しました」と拒否されて**利用者は同じ依頼を再送するしかなかった**。いまは同じ依頼のまま次のturnで起動できる。

`/external-plan`と`/opus-plan`は同じtaskで併用できない。ただし拒否ではなく**後から打ったcommandが前のrouteを退役させる**（`superseded-by-command`）。taskが同時に持つdesign routeは常に1つで、打ち間違いや気変わりはcommandを打ち直せば直る。repository、skill、tool結果、model生成文に書かれたcommandは起動根拠にならない。

## シェルの連結

mainのshellは`&&`・`||`・`;`・`|`で連結できる。allowlistは**各セグメント**に対して評価され、1つでもallowlist外があれば連結全体がsandbox escalationと承認を要求する。したがって`git status && curl https://example.invalid` のような「許可されたcommandの後ろに禁止command」は、単体の`curl`と同じ扱いで拒否される。

`>`・`>>`・`` ` ``・`$( )`・`&`（単独）・改行は連結として扱わない。これらはshellが実行内容を組み立てる構文であり、このpolicyが読むtextと実際に走るcommandが食い違うため、行全体が「読めない」ものとして承認を要求する。`echo x > .env`は保護path変更として拒否される。

Gitの変更（`git add`・`git commit`・`git restore --staged`）は**単一commandでのみ**許可する。1 pathのstage規則と「stagedは厳密に1 file」規則は1つのargvを読むため、連結に隠れた変更は承認があっても拒否する。

## 導入

前提はNode.js `22.19.0`以上とDSH `0.1.7-rc.2`。標準presetはコピーしない。web profileへこのbundleを後段layerとして追加する。

```bash
dsh --version
dsh --profile dsh-main --from-default-profile web --help
dsh plugin --profile dsh-main add file:/absolute/path/to/ai-agent-rules/dsh
dsh --profile dsh-main --dump-config
dsh --profile dsh-main
```

既存の`dsh-main` profileがある場合は2行目を実行しない。導入後の`--dump-config`で次を確認する。

- `agent-default-model`が`deepseek-official` / `deepseek-flash`
- `llm-pi-ai`に`zai`、`anthropic`、`openai`
- model-facing toolが`external_research_design`、`external_opus_design`、`external_code`、`review_change`
- 各toolのprovider、model、`reasoningEffort`、`maxTokens`、`toolFilter`、`maxDepth: 1`
- `dsh-main-policy`が有効

### 再installが必要な場合

pnpmは`file:`依存に対して`Already up to date`を返すことがあり、その場合profileは最初に入れた版を配り続ける。working treeの変更がprofileへ届いていない疑いがあるときは、install済みcopyを消してから入れ直す。

```bash
rm -rf "$DSH_HOME/profiles/dsh-main/node_modules/@kaikojima"
dsh plugin --profile dsh-main add file:/absolute/path/to/ai-agent-rules/dsh
```

`npm test`のE2Eはbundleを一時`DSH_HOME`へ毎回入れ直すので、この経路を常時検証している。

### 必須credential名

API key値をrepository、profile patch、sessionへ書かない。DSHのSettings → Modelsで保存するか、起動processへ次の環境変数を渡す。

```text
DEEPSEEK_API_KEY
ZAI_API_KEY
ANTHROPIC_API_KEY
OPENAI_API_KEY
```

DeepSeek公式adapterは`DEEPSEEK_API_KEY`を使う。外部provider設定には環境変数名だけが入り、値は入らない。解決はrequest時に行われるため、key未設定でもprofile起動は成功し、該当routeを実行した時点で`MISSING_CREDENTIAL`として失敗する。

## slash commandの使い方

4つのcommandはDSHのcommand registryへ登録される。Web composerで行頭に`/`を打つと候補へ出る。

```text
/external-plan <依頼内容>
/opus-plan <依頼内容>
/external-code <実装依頼>
/review <review依頼>
```

task本文はcommandと同じ行の引数として渡す。commandを受理したhandlerがtask本文とrouting intent contextを1つのuser messageとしてagentへ配送し、そのmessageが入ったturnへintentを束縛する。commandの行だけを送って本文を後から送る使い方もできる（本文の配送は次のturnになる）。引数なしのcommandは本文を要求して失敗し、composerのdraftを保持する。

commandはturnの外から実行できる。turnが開いていないことを理由に拒否しない。dispatchは`ctx.commands.execute`の経路を通り、`command/run`と`command/done`がsession logへ残る。

## 外部coder入力

`external_code`へ渡すpromptに次のmachine-readable blockを1つ含める。pathはworkspace相対、commandは`&&`・`||`・`;`・`|`以外のshell制御構文を含まないcommandに限定する（各commandは`allowedCommands`の要素として個別に並べる）。

```text
<implementation_handoff>
{
  "objective": "確定した詳細設計を実装する",
  "allowedPaths": ["src/feature", "test/feature.test.ts"],
  "forbiddenPaths": ["src/feature/legacy.ts"],
  "allowedCommands": ["npm test -- feature.test.ts"],
  "requiredTests": ["feature.test.tsが成功する"]
}
</implementation_handoff>
```

coder実行中は同一workspaceのmain write・shell・Gitを止める。coderは`allowedPaths`外へwriteできず、`allowedCommands`以外を実行できず、Git・network・sandbox拡張・再委譲を使えない。成功したforeground terminal resultだけがlockを解放する。timeout、不明status、tool errorではlockを保持する。

## review入力・出力

`review_change`へ渡すpromptに次を含める。

```text
<review_input>
{
  "base": "40桁のcommit SHA",
  "head": "40桁のcommit SHA",
  "requirementsHash": "sha256:requirementsのUTF-8文字列に対する64桁のhex",
  "requirements": "review対象の要求"
}
</review_input>
```

reviewerは固定SHAを含むGit read-only commandだけを実行できる。mainのwrite・shellはreview完了まで停止する。結果は`status`、入力と同じSHA/hash、`findings`を持つJSONだけを受理する。`incomplete`は未確認範囲を必須とし、問題なしへ変換しない。

## mutation lockの回復

残留lockがある場合、次回起動はfail-closedになる。該当child／processの停止とworkspace差分を人間が確認し、次を診断用に退避してから再起動する。自動削除しない。

```text
$DSH_HOME/dsh-main-policy/mutation-lock.json
```

退避名は任意だが内容を残すこと。lockだけを消して再起動すると、coderの終了statusが未確認のままworkspaceが解放される。

## protection

構造化write/editとshellの両方で次を保護する。

- `.git/**`、`.agents/**`、`.dsh/**`、`.codex/**`、`.claude/**`、`hooks/**`
- `skills/**`（skill本文は権限の根拠であり、書き換えられると自分自身へ権限を与えられる）
- `AGENTS*.md`、`CLAUDE*.md`、`cordis*.yml`、`settings.yaml`、`.credentials.yaml`
- `.env*`、主要lockfile、review state、mutation lock
- symlinkで到達する保護path、hard-linked file、`..`を含むworkspace外path

mainの通常shellはread／test／lint／typecheck／buildの保守的allowlistに限定する。連結は**全セグメントがallowlist内**のときだけ通り、1つでも外れればDSH sandbox escalationと人間の承認が必要（`git status && curl …` のような隠しは単体の`curl`と同じ判定になる）。Gitはread-only command、1 pathの`git add`、stageが厳密に1 fileの`git commit`、indexだけのrestore以外を拒否する。外部plannerとreviewerはread-only。reviewerのshellは固定base/headを含むGit readだけを許可する。

## 検証

```bash
cd dsh
npm test
```

`npm test`が静的検証・unit suite・実DSH E2Eを通す。E2Eは一時`DSH_HOME`、使い捨てGit workspace、loopback mock providerだけを使い、外部APIへ接続せず課金requestも送らない。unitだけを速く回したい場合は`DSH_DISABLE_E2E=1 npm test`。

`npm run verify`も同じ検証を通る（`verify.mjs`がunit suiteとE2Eを順に実行する）。`pretest`が一時fileを掃除する。

## skillの配置

配布元`skills/`のskill bundleは、bundle自身のprovider（`lib/distribution-skills.js`）が`import.meta.url`から解決した`<bundle>/skills`を配信する。profileへinstallされたcopyがそのまま配信元になるため、profile側の設定へ絶対pathを書かない。DSH標準の`dsh-skill-filesystem`は`.dsh/skills`と`.agents/skills`を追加で探索するので、projectローカルのskillは従来どおり併用できる。

`disable-model-invocation`と`user-invocable`の実効値、および各skillの分類は`SKILL_CLASSIFICATION.md`を正本とする。

## 未保証範囲

- OS-levelの排他ではない。配布hookを通らないtool、外部editor、起動済みprocessの継続は対象外
- reviewerのtest・network禁止はtoolFilterとcommand検査に依存し、sandbox policyによる強制ではない
- `agent.options`からroleを解決できない場合、role判定は補助に留まる。実際の境界はmutation lockとreview lock
- commit subjectの文言規約、再指摘の意味的同定は機械保証しない
- 責務単位の棚卸しと各項目の分類は`HOOK_RESPONSIBILITIES.md`を正本とする

## rollback条件

保護path write、policy fail-open、cancel後のmutation、route実効値不一致、明示flagなしの外部起動、session／review対象の誤照合が1件でもあればprofileを停止する。stateは削除せずread-onlyで退避し、既存Codex／Claude／DeepSeek bridgeへ戻す。既存配布物の削除はこのbundleの導入範囲外。
