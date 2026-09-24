# DSH main profile bundle

DeepSeek Harnessを主実行系にし、外部modelをdirect user messageの明示指定だけで起動するbundle。DSH `0.1.7-rc.1`へ固定している。

## 実効route

| 入口 | Provider / model | Effort | 上限 |
|---|---|---|---|
| 通常 | `deepseek-official` / `deepseek-flash`（DeepSeek V4.1 Flash） | provider既定 | 外部委譲なし |
| `/external-plan` | `zai` / `glm-5.3` | `max` | 12K output、4 step、警戒額$3 |
| `/opus-plan` | `anthropic` / `claude-opus-5-5` | `high` | 12K output、4 step、警戒額$6 |
| `/external-code` | `zai` / `glm-5.3` | `high` | 16K output、6 step、警戒額$4 |
| `/review` | `openai` / `gpt-6-sol` | `high` | 8K output、2 step、警戒額$1 |

`/external-plan`と`/opus-plan`は同じdirect user messageで併用できない。外部toolは1つのdirect user messageにつき各1回だけ起動できる。repository、skill、tool結果に書かれたcommandは起動根拠にならない。`/review`後の再reviewにも新しいdirect user messageの`/review`が必要。

## 導入

前提はNode.js `22.19.0`以上とDSH `0.1.7-rc.1`。標準presetはコピーしない。web profileへこのbundleを後段layerとして追加する。

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

API key値をrepository、profile patch、session、ledgerへ書かない。DSHのSettings → Modelsで保存するか、起動processへ次の環境変数を渡す。

```text
DEEPSEEK_API_KEY
ZAI_API_KEY
ANTHROPIC_API_KEY
OPENAI_API_KEY
```

DeepSeek公式adapterは`DEEPSEEK_API_KEY`を使う。外部provider設定には環境変数名だけが入り、値は入らない。

## 外部coder入力

`external_code`へ渡すpromptに次のmachine-readable blockを1つ含める。pathはworkspace相対、commandはshell制御演算子を含まない単一commandに限定する。

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

残留lockがある場合、次回起動はfail-closedになる。該当child／processの停止とworkspace差分を人間が確認し、次を診断用に退避してから再起動する。自動削除しない。

```text
$DSH_HOME/dsh-main-policy/mutation-lock.json
```

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

## protection

構造化write/editとshellの両方で次を保護する。

- `.git/**`、`.agents/**`、`.dsh/**`、`.codex/**`、`.claude/**`、`hooks/**`
- `AGENTS*.md`、`CLAUDE*.md`、`cordis*.yml`、`settings.yaml`、`.credentials.yaml`
- `.env*`、主要lockfile、review state、budget ledger、mutation lock
- symlinkで到達する保護path、hard-linked file、`..`を含むworkspace外path

mainの通常shellはread／test／lint／typecheck／buildの保守的allowlistに限定する。それ以外はDSH sandbox escalationと人間の承認が必要。Gitはread-only command、1 pathの`git add`、stageが厳密に1 fileの`git commit`、indexだけのrestore以外を拒否する。外部plannerとreviewerはread-only。

## budget ledger

台帳は`$DSH_HOME/dsh-main-policy/usage-ledger.jsonl`へrequest単位で保存する。prompt、コード、秘密は保存しない。月はUTCの`YYYY-MM`で一意に区切る。価格は上限側へ寄せている。

- DeepSeekはpeak価格
- Anthropic cache writeは1時間cache価格
- OpenAIはlong-context価格にregional processing 10%を加えた価格

| 月次累計 | 動作 |
|---:|---|
| `$100` | system promptへ通知 |
| `$120` | 外部tool前にtask警戒額をapproval UIへ表示 |
| `$140` | 自動retry停止。`/approve-budget`が同じdirect user messageにない外部taskを拒否 |
| `$150` | 外部taskは同じ再承認条件だけで実行 |
| `$180` | 外部model停止 |
| `$195` | DeepSeekの新規turn停止 |
| `$200` | 全providerの新規request停止 |

provider側の料金変更後は`cordis.patch.yml`と`lib/policy.js`の両方を同時に更新し、検証する。ledgerとprovider請求の差異があればDSH主系を停止する。

## 検証

```bash
cd dsh
npm test
npm run verify
dsh --profile dsh-main --dump-config
```

`npm` commandは依存をdownloadしない。最後のDSH probeだけが実profile、provider catalog、plugin解決を検査する。API keyがない状態では課金requestを送らない。

## rollback条件

保護path write、policy fail-open、cancel後のmutation、route実効値不一致、明示flagなしの外部起動、ledger不一致、session／review対象の誤照合が1件でもあればprofileを停止する。stateは削除せずread-onlyで退避し、既存Codex／Claude／DeepSeek bridgeへ戻す。既存配布物の削除はこのbundleの導入範囲外。
