# Claude Max CLI adapter implementation plan

## 1. 結論

`/opus-plan`のtransportをAnthropic API subagentからClaude Code CLIへ置き換える。
DSH mainは引き続きDeepSeek公式APIを使い、Claude Maxの契約枠は`claude -p`からのみ消費する。

再開単位はDSHのrouting intentとする。

```text
DSH session A / routing intent 1 -> Claude session aaa
DSH session B / routing intent 1 -> Claude session bbb
DSH session A / routing intent 2 -> Claude session ccc
```

同じrouting intentから2回目以降に`external_opus_design`を呼んだ場合だけ、保存済みのClaude `session_id`を`--resume`へ渡す。別task、別intent、別DSH sessionへClaude sessionを再利用しない。

この計画では複数ホスト間のsession移送を扱わない。同一ホスト上で複数DSH taskが独立したClaude sessionを持つことだけを保証する。

## 2. 目的

- DeepSeekをDSH mainとして維持する。
- `/opus-plan`だけClaude Max 5xの契約枠を使う。
- Anthropic APIの従量課金へ自動または暗黙に切り替わらないようにする。
- 同一taskの追加調査と設計更新でClaude sessionを再開する。
- 複数taskの会話履歴を混線させない。
- 現行のrouting intent、read-only planner境界、Design Handoff検証、fail-closed方針を維持する。
- DSH E2Eでは外部APIとClaude実サービスを呼ばない。

## 3. 対象外

- Claude Max残量の予測。
- 5時間枠・週次枠の独自計算。
- 利用上限到達時のAnthropic APIへの自動fallback。
- Claude ProでのOpus利用可否の吸収。
- 複数ホスト間でのClaude session複製。
- DSH再起動後に、閉じられたrouting intentを自動復活させること。
- Claude API互換transportの一般化。
- `/external-plan`、`/external-code`、`/review`のCLI化。
- Claudeによるfile編集、Git操作、test実行、外部model起動。

## 4. 現状

現在の`/opus-plan`は次の経路を使う。

```text
/opus-plan
  -> routing intent
  -> external_opus_design
  -> @deepseek-ai/dsh-tool-subagent
  -> llm-pi-ai / anthropic-messages
  -> claude-opus-5-5 API
```

現在の重要な性質は維持する。

- commandはdirect user dispatchだけが作成できる。
- routing intentはturn終了や1回のtool成功では閉じない。
- 同じintentは`external_opus_design`を何度でも認可できる。
- 新しいcommandは既存intentを`superseded-by-command`で閉じる。
- plannerはread-onlyで、Design Handoff以外を成功として扱わない。
- 外部routeは別modelを起動できない。
- 不明statusや未検証結果を成功へ変換しない。

今回変更するのは`external_opus_design`のtransportだけである。

## 5. 目標構成

```text
/opus-plan <task>
  -> RoutingIntentStore
  -> external_opus_design
  -> ClaudeMaxCliAdapter
       -> stored ChatGPT/Claude Max login
       -> claude -p --model <exact-opus-model>
       -> JSON or stream-json output
  -> validateDesignHandoff
  -> DeepSeek main
```

継続時は次の経路になる。

```text
same DSH session
same routing intent
  -> ClaudeSessionStore lookup
  -> claude -p --resume <claude-session-id>
  -> updated Design Handoff
```

## 6. 事前検証

実装開始前に、対象ホストで以下を実機確認する。

1. Claude Codeを最新版へ更新する。
2. Claude Max 5xのアカウントでログインする。
3. API credentialを渡さないclean environmentで`claude -p`が成功する。
4. `--model opus`または正確なOpus 5.5 model idが受理される。
5. JSON出力に`session_id`、`result`、`is_error`、`num_turns`が含まれる。
6. 取得した`session_id`を`--resume`へ渡し、前turnの文脈を参照できる。
7. 利用上限到達時のexit code、stderr、JSON subtypeを記録する。
8. `ANTHROPIC_API_KEY`が存在しない状態で、Anthropic Console残高が減らないことを確認する。
9. 実際に使用されたmodelをstream-jsonのinit eventから確認できるか調べる。

実モデル名またはsubscription認証を機械確認できない場合、推測で続行しない。確認不能を既知の制約として明示し、初期版は起動前preflightと利用者確認を必須にする。

## 7. 新規module

### 7.1 `lib/claude-max-cli.js`

Claude CLI processの構築、実行、出力解析だけを担当する。

責務：

- Claude binaryのpath解決。
- child process用environmentの作成。
- API・proxy・Bedrock・Vertex系credentialの除去。
- promptのstdin入力。
- `--model`、`--permission-mode`、`--max-turns`、tool制限の固定。
- 初回runとresume runのargument構築。
- timeoutとabort signalの伝播。
- stdout JSONまたはJSONLの解析。
- stderrの取得。
- `session_id`、最終result、turn数、error分類の返却。
- model mismatch、空result、parse errorを失敗にする。

想定interface：

```js
runClaudePlan({
  cwd,
  prompt,
  resumeSessionId,
  signal,
  timeoutMs,
  executable,
  model,
})
```

返却値：

```js
{
  status: 'success' | 'usage-limit' | 'auth-required' | 'timeout' | 'failed',
  sessionId,
  result,
  numTurns,
  stderr,
  rawMetadata,
}
```

### 7.2 `lib/claude-session-store.js`

DSH routing intentとClaude sessionの対応を永続化する。

保存先：

```text
$DSH_HOME/dsh-main-policy/claude-max-sessions.json
```

schema：

```json
{
  "version": 1,
  "sessions": [
    {
      "dshSessionId": "session-a",
      "intentId": "intent-uuid",
      "claudeSessionId": "abc123",
      "workspace": "/absolute/repository/path",
      "model": "opus",
      "status": "ready",
      "createdAt": "2026-09-28T00:00:00.000Z",
      "updatedAt": "2026-09-28T00:00:00.000Z",
      "lastRunId": "run-uuid",
      "lastResultStatus": "success"
    }
  ]
}
```

要件：

- state root外を指定できない。
- symlink、hard link、非regular fileを拒否する。
- mode `0600`でatomic writeする。
- lookup keyは`dshSessionId + intentId`とする。
- workspace不一致時はresumeしない。
- 新しいintentへ古いClaude sessionを引き継がない。
- closed intentのrowは`closed`へ更新し、自動再利用しない。
- state parse失敗はprofile起動またはroute実行をfail-closedにする。

## 8. Claude processの固定条件

初期実装は次を固定する。

```text
mode: print / non-interactive
model: exact Opus 5.5 id or verified `opus` alias
output: stream-json preferred; json acceptable after preflight
permission mode: plan
max turns: configuration value with conservative default
cwd: DSH workspace
```

許可tool：

- Read
- Glob
- Grep
- WebSearch
- WebFetch

禁止tool：

- Write
- Edit
- NotebookEdit
- Bash
- Git mutation
- task/subagent delegation
- arbitrary MCP not explicitly needed by the planner

CLI built-inのplan modeだけに依存せず、DSHが作るpromptでもread-only境界を再宣言する。

## 9. credential分離

Claude child processへ次のcredentialを渡さない。

```text
ANTHROPIC_API_KEY
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL
CLAUDE_CODE_USE_BEDROCK
CLAUDE_CODE_USE_VERTEX
ANTHROPIC_BEDROCK_BASE_URL
ANTHROPIC_VERTEX_BASE_URL
```

DSH本体の環境を変更せず、child processのenvironment copyからだけ除去する。

要件：

- API credentialがchildへ残っている場合は起動しない。
- subscription loginが無ければ`auth-required`で終了する。
- 上限到達時にAPI利用を勧めるpromptや自動切替を受理しない。
- Anthropic API providerへの自動fallbackを実装しない。
- subscription routeの失敗はDeepSeek mainへ構造化して返す。

## 10. routing intentとの統合

### 初回call

1. 既存policy hookが`external_opus_design`を認可する。
2. `dshSessionId + intentId`でClaude session storeを検索する。
3. rowが無ければ新規`claude -p`を起動する。
4. 出力からClaude `session_id`を取得する。
5. Design Handoffを`validateDesignHandoff`で検証する。
6. session mappingとcall outcomeをatomic保存する。
7. 検証済みDesign HandoffだけをDeepSeek mainへ返す。

### 継続call

1. 同じrouting intentを認可する。
2. storeからClaude `session_id`を取得する。
3. workspaceとmodelを照合する。
4. `--resume <session_id>`で追加promptを送る。
5. 更新後のDesign Handoffを検証する。
6. call outcomeとtimestampを更新する。

### 新しいcommand

- 現行intentをclosedにする。
- Claude session rowもclosedにする。
- 新commandは必ず新しいClaude sessionを開始する。
- `/external-plan`と`/opus-plan`の排他規則を変えない。

### DSH再起動

現在は起動時にopen intentを`restart`で閉じる。この規則を維持する。

- Claude session rowは診断用に残す。
- 再起動後に自動resumeしない。
- userが新しい`/opus-plan`を発行した場合は新規Claude sessionとする。
- cross-restart resumeが必要になった時だけ、別仕様として明示的なtask resume commandを設計する。

## 11. 同時実行

異なるintentは同時実行を許可する。

```text
intent A -> Claude session aaa
intent B -> Claude session bbb
```

同じintentの同時実行は拒否する。

- keyは`dshSessionId + intentId`。
- process内in-flight mapで排他する。
- 二重callは`route already running`として失敗させる。
- plannerはread-onlyなのでworkspace mutation lockは使わない。
- 将来process crash後の重複課金が問題になった場合だけpersisted leaseを追加する。

## 12. error分類

最低限、次を区別する。

| status | 意味 | DSHの扱い |
|---|---|---|
| `success` | 検証済みDesign Handoff | mainへ返す |
| `usage-limit` | Claude Maxの利用枠到達 | 自動fallbackせず報告 |
| `auth-required` | Max login無し・期限切れ | 再loginを要求 |
| `model-unavailable` | Opus利用不可 | 別modelへ落とさず失敗 |
| `model-mismatch` | 実modelが期待と不一致 | 結果を破棄 |
| `timeout` | CLI timeout | session idを保存し、再開可否を報告 |
| `cancelled` | user/parent中断 | session idを保存し、完了扱いしない |
| `invalid-output` | JSONまたはDesign Handoff不正 | 結果を破棄し、同intentで再実行可 |
| `failed` | その他 | stderrとexit codeを保存 |

error textだけを正規表現で判定する実装を最終形にしない。CLIがstructured errorを返す場合はそれを優先し、未知のerrorは`failed`へ閉じる。

## 13. profile変更

`cordis.patch.yml`の`dsh-main-external-opus-design`を、`@deepseek-ai/dsh-tool-subagent`＋Anthropic providerからbundle自身のCLI-backed toolへ変更する。

変更方針：

- tool名`external_opus_design`は維持する。
- command名`/opus-plan`は維持する。
- persona本文は正本を1箇所に移し、API routeとCLI routeへ複製しない。
- `llm-pi-ai`のAnthropic providerは、他用途が無ければ削除する。
- `ANTHROPIC_API_KEY`を必須credential一覧から削除する。
- rollback用にAPI transportを残す場合も自動fallbackはしない。
- transport選択はprofile起動時の明示configにし、task中に切り替えない。

推奨config：

```yaml
opusPlanTransport: claude-max-cli
claudeExecutable: claude
claudeModel: opus
claudeMaxTurns: 12
claudeTimeoutMs: 1800000
```

## 14. policy変更

`lib/policy.js`と`index.js`で次を更新する。

- API provider/modelからexternal roleを解決していた前提を、CLI-backed routeには適用しない。
- tool名とrouting intentによる認可を正本にする。
- CLI routeでもDesign Handoff検証を必須にする。
- external roleからの再委譲禁止をpromptとCLI tool制限で維持する。
- CLI route実行中にmain writeを止めるかは別判断とする。初期版はplanner read-onlyのためmutation lockを取らない。
- call resultへClaude session idとCLI statusを診断metadataとして記録する。
- API route declaration検証からClaude model declarationだけを外し、CLI config declarationの検証へ置き換える。

## 15. test計画

### 15.1 unit test

`test/claude-max-cli.test.js`：

- 初回argumentが`--resume`を含まない。
- 継続argumentが正しいsession idを含む。
- promptがargvではなくstdinへ入る。
- API credentialがchild environmentから除去される。
- plan mode、model、turn上限、tool制限が固定される。
- success JSONを解析できる。
- session id欠落を拒否する。
- 空resultを拒否する。
- malformed JSONを拒否する。
- timeout、cancel、auth、usage limit、unknown errorを区別する。
- model mismatch時に結果を返さない。

`test/claude-session-store.test.js`：

- 同一intentの2回目が同じClaude sessionを使う。
- 別intentは新規sessionになる。
- 別DSH sessionへsession idを漏らさない。
- workspace mismatchを拒否する。
- closed rowをresumeしない。
- atomic write、mode、symlink、hard link検査。
- invalid versionと破損JSONでfail-closed。

### 15.2 routing/policy test

- `/opus-plan`以外でCLI toolを起動できない。
- `/external-plan`後に`/opus-plan`を打つとGLM routeが閉じる。
- `/opus-plan`後に別commandを打つとClaude session rowがclosedになる。
- 同じintentの再callは許可される。
- 同じintentの並列callは拒否される。
- restartでintentは閉じ、Claude sessionを自動再開しない。
- invalid Design Handoffをmainへ返さない。
- API fallbackが存在しない。

### 15.3 E2E

実Claude CLIを呼ばず、PATH先頭へmock `claude` executableを置く。

mockは次を検証できるようにする。

- 初回は`session_id: mock-1`を返す。
- 2回目は`--resume mock-1`を要求する。
- 別taskは`session_id: mock-2`を返す。
- usage-limit、auth failure、timeout、malformed JSONをfixtureで返す。
- stdinにrole境界とtask本文が含まれることを記録する。
- API credentialがprocess環境に無いことを確認する。

既存のloopback mock provider E2EはDeepSeek、GLM coder、review routeの検証として残す。

## 16. documentation変更

実装時に次を更新する。

- `README.md`
  - `/opus-plan`のtransportをClaude Max CLIとして記載。
  - 初回login手順。
  - API keyを使わないこと。
  - session resumeの範囲。
  - 利用上限時に自動fallbackしないこと。
- `AGENTS.dsh.md`
  - role境界は変更しない。
  - provider固定の表現をCLI transportでも矛盾しないよう更新。
- `HOOK_RESPONSIBILITIES.md`
  - session store、credential scrub、CLI process、resume、error分類の責務を追加。
- `SKILL_CLASSIFICATION.md`
  - 変更不要を原則とし、Claude CLIへskillを自動配布しないことを確認。
- `cordis.patch.yml`
  - Anthropic API routeをCLI-backed toolへ置換。

## 17. rollout

### Phase 0: spike

- Max 5x契約環境でJSON schemaとsession resumeを確認。
- Opus 5.5 model選択の実効値を確認。
- API残高が減らないことを確認。
- usage limit errorの実出力を保存。

### Phase 1: isolated adapter

- `claude-max-cli.js`とsession storeを実装。
- mock executableによるunit testを完了。
- DSH routeへまだ接続しない。

### Phase 2: route integration

- `external_opus_design`だけCLI transportへ切り替える。
- 既存policy、routing、E2Eを通す。
- API fallbackを無効のままにする。

### Phase 3: canary

- 既知の小規模設計taskで初回callを確認。
- 同一intentで追加質問し、resumeを確認。
- 別taskを起動し、session混線がないことを確認。
- Claude Max利用dashboardとAnthropic Console残高を確認。

### Phase 4: regular use

- `/opus-plan`だけで使用。
- 利用上限、認証切れ、resume失敗を1か月記録。
- 問題が無ければ手動運用を廃止する。

## 18. rollback

次のいずれかが起きたらCLI transportを停止する。

- API残高を意図せず消費した。
- Opus以外へ黙って切り替わった。
- 別taskのClaude sessionを再利用した。
- resume失敗後に新規sessionへ黙って切り替わった。
- plannerがwrite、shell、Git mutationを実行した。
- 利用上限を一般errorとして再試行し続けた。
- JSON parse失敗を成功扱いした。
- DSH restart後に古いintentを自動再開した。

rollbackは明示configでAnthropic API transportへ戻すか、`/opus-plan`を一時無効にする。CLI失敗時に同じtask内で自動的にAPI課金へ切り替えない。

## 19. 受入条件

- Claude Max認証だけで`/opus-plan`が成功する。
- Anthropic Console API残高を消費しない。
- 初回runのClaude session idが安全に保存される。
- 同じrouting intentの次回runがそのsession idをresumeする。
- 別intent、別DSH session、別workspaceがsession idを共有しない。
- 同じintentを並列実行できない。
- `--continue`を使わない。
- model mismatch、auth failure、usage limit、timeout、invalid outputを区別できる。
- 利用上限時にAPIへ自動fallbackしない。
- plannerはread-onlyで、Design Handoffだけを返す。
- 既存のGLM planner、GLM coder、Sol reviewerの挙動を変えない。
- mock CLIを使うunit/E2Eが外部通信なしで通る。
- `npm test`と`npm run verify`が成功する。

## 20. 実装順序

1. 実Claude CLIのJSON、model、auth、resume、limit errorをspikeする。
2. session storeとschemaを実装する。
3. CLI process adapterをmock駆動で実装する。
4. Design Handoff validatorへ接続する。
5. routing intent lifecycleへsession rowのopen/closeを接続する。
6. `external_opus_design`をCLI-backed toolへ差し替える。
7. Anthropic API credential依存をprofileから除去する。
8. unit、policy、routing、E2Eを追加する。
9. READMEと責務表を更新する。
10. canary後に通常運用へ移す。

## 21. 実装前に確定する事項

- 実機で受理されるOpus 5.5の正確なCLI model id。
- stream-json init eventから実modelを検証できるか。
- Max subscription利用時のJSON `total_cost_usd`の意味。
- usage limit時のstructured outputとexit code。
- timeout後のsessionを安全にresumeできるか。
- Claude Codeがsubscription認証中であることを非対話で確認する手段。
- DSH custom toolがabort signalとparent session id／intent idを受け取る正確なextension point。

これらはPhase 0で確認し、未確認のまま実装へ埋め込まない。
