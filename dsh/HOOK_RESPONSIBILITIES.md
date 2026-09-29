# Hook責務の棚卸しとDSH native移植状況

既存の`hooks/shell/*`を**名前単位ではなく責務単位**で棚卸しし、各責務がDSHでどう強制されるかを記録する。分類は次の4つ。

| 分類 | 意味 |
|---|---|
| native移植済み | DSH native plugin（`dsh/index.js`／`dsh/lib/*`）が強制する |
| DSH標準sandboxへ委譲 | DSH本体またはsandbox policyが強制する。このbundleは関与しない |
| legacy専用でDSH非該当 | Claude／Codex固有の機構に依存し、DSHに対応物が無い |
| 未移植 | 現時点でDSH側の保証に含めていない |

## 責務一覧

| 責務 | 既存実装 | DSHでの分類 | DSH側の実装・根拠 |
|---|---|---|---|
| protected path判定 | `protected-exec.py`、`safe-files.py` | native移植済み | `protectedPathReason`（`lib/policy.js`）を`tools.guard`の`write`／`edit`で評価 |
| `.git`保護 | `protect-git.sh`、`git-policy.py` | native移植済み | `PROTECTED_COMPONENTS`の`.git`＋`gitCommandPolicy`がGit書き込みを拒否 |
| agent設定・hook・`.env`・lockfile・review state保護 | `protect-config.sh`、`protect-env.sh`、`protect-locks.sh`、`protect-review.sh` | native移植済み | `PROTECTED_BASENAMES`（`AGENTS*.md`、`CLAUDE*.md`、`cordis*.yml`、`settings.yaml`、`.credentials.yaml`、lockfile群）を構造化writeとshellの両方で評価 |
| skill source保護 | `deny-skill-source.sh` | native移植済み | `PROTECTED_COMPONENTS`の`skills`。skill本文は権限の根拠なので、書換えを構造化write・shell・`git add`のすべてで拒否 |
| symlink・hard link経由の保護path変更 | `protected-exec.py` | native移植済み | `canonicalTarget`が実体を解決し、`nlink > 1`を拒否 |
| shell迂回の拒否 | `git-policy.py`、`require-implementer.sh` | native移植済み | `shellProtectedMutationReason`＋`needsRawShellApproval` |
| Git read allowlist | `git-policy.py` | native移植済み | `READ_ONLY_GIT`と`gitCommandPolicy`の`read` |
| 1ファイルstage／1ファイルcommit | `commit-gate.sh` | native移植済み | `gitCommandPolicy`の`add`／`commit`と、commit時の`stagedFiles`件数検査 |
| commit subject規約 | `commit-subject.sh` | legacy専用でDSH非該当 | `commit-subject.sh`はClaude／Codex配布契約。DSH mainのcommit粒度はnative guardが強制するが、subject文言規約はこのbundleの対象外 |
| 外部coder中のmain mutation停止 | `deepseek-worker.sh`、`deepseek-worker.py` | native移植済み | `mutation-lock.json`。coder起動時に取得し、main write・shell・Gitを拒否 |
| cancel・timeout・不明status時のlock保持 | `deepseek-worker.py` | native移植済み | 成功したforeground terminal resultだけがlockを解放。`runId`が無ければ`stop-unconfirmed`で保持 |
| reviewer中の変更停止 | `protect-review.sh`、`independent-review.sh` | native移植済み | `reviewLocks`がworkspaceを凍結し、main write・shellを拒否 |
| review base／head／requirements hash固定 | `independent-review.sh` | native移植済み | `parseReviewInput`＋`verifyReviewRepository`が実SHAを照合。`validateReviewOutput`が結果のSHA/hash一致を要求 |
| reviewerのread-only強制 | `protect-review.sh` | native移植済み | `reviewGitCommandAllowed`が固定SHA付きGit readだけを許可 |
| 外部roleの再委譲禁止 | 各role hook | native移植済み | `GENERIC_DELEGATION_TOOLS`を`agent.ctx.tools.restrict`でdeny。depth>0では外部route toolもdeny |
| context／contract配送 | `load-required-contract.sh`、`load-operation-context.sh` | native移植済み | `ctx.systemPrompt.section`（`DSH_INSTRUCTIONS`、`MAIN_POLICY_PROMPT`）＋subagent `persona` |
| session継続・resume・compaction | `session.sh` | DSH標準sandboxへ委譲 | `dsh-session-persistence`／`dsh-compaction`が担当。skill scope markerは`dsh-skill`のcatalogへ置換 |
| resultのsession ID・task ID・terminal status照合 | `agent-wait.sh`、`agent-input.py` | native移植済み | 外部route toolの各呼出は`runId`と`resultStatus`をintentの呼出記録へ残し、終端foreground resultだけを受理。routeの許可はturnではなくtaskの事実（新command・dispose・再起動）で終わる |
| 専用role指定の起動tool検査 | `require-implementer.sh` | native移植済み | route tool名を固定し、各toolの`agentOptions`でprovider／model／effortを固定。roleはその組から解決するので、組の重複は`assertRouteCommandConsistency`が起動時に拒否する。routeのmodel entryが話すprotocolの必要compat（`anthropic-messages`の`forceAdaptiveThinking`）を宣言しているかは`assertRouteDeclarations`が起動時に拒否する |
| 通常commandのallowlist | `command-approval.sh` | native移植済み | `SAFE_MAIN_COMMAND`。それ以外はsandbox escalationと承認を要求 |
| slash commandの登録とtask配送 | （新規） | native移植済み | `ctx.commands.register`で4 commandを登録。handlerが`agent.followup`でtask本文とrouting intent contextを配送し、`agent/pre-step`でintentを配送turnへ束縛する |
| OS-levelのread-only強制 | `agent-input.py`（sandbox mode） | DSH標準sandboxへ委譲 | DSH sandbox policyが担当。このbundleはtool単位の境界のみ持つ |
| Baton model switch | `pre-model-switch.sh` | legacy専用でDSH非該当 | DSHにBaton接続が無い。model固定はprofileが担う |
| Claude／Codexのevent schema差吸収 | `hook-io.sh` | legacy専用でDSH非該当 | DSHは`tools.guard`／`session/event`等のnative eventを直接使う |
| skill scope marker | `session.sh` | legacy専用でDSH非該当 | DSHのskill catalogと`disable-model-invocation`が置換 |
| Windows専用分岐、MCP保護 | `mcp-protected.sh`、`outside.sh` | legacy専用でDSH非該当 | 対象外 |
| commit subject文言の意味判定 | `commit-subject.sh` | 未移植 | 安全保証に含めない。1ファイル1コミットの粒度のみ保証する |
| 再指摘の意味的同定 | `independent-review.sh` | 未移植 | 人間の採否判断。機械保証に含めない |

## fail-closedの境界

`dsh-main-policy`の`apply`が投げるとprofile起動が失敗する。warningのみで起動継続する経路は無い。

- 必要service（`agents`／`commands`／`skills`／`systemPrompt`／`tools`）が欠落 → 起動失敗
- routing-intent stateの破損・非対応version・malformed record → 起動失敗（`activation-error.txt`に原因を記録）
- 解決不能なmutation lockの残留 → 起動失敗
- route tableとcommand registryの不一致 → 起動失敗
- 2つのrouteが同じ`provider`/`model`組を宣言 → 起動失敗（roleが解決不能になり、そのrole向けguardが許可すべき仕事を拒否するため）
- routeのmodel entryが必要compatを宣言していない、route／model／apiがpatchに無い → 起動失敗（課金前にproviderが拒否し、呼出側にはroute名も欠落fieldも見えないため）
- `AGENTS.dsh.md`が読めない、または指示blockが空 → 起動失敗

## 未保証範囲

- reviewerのtest・network禁止はtoolFilterとcommand検査に依存し、sandbox policyによる強制ではない
- OS-levelの排他ではない。配布hookを通らないtool、外部editor、起動済みprocessの継続は対象外
- `agent.options`からroleを解決できない場合、role判定は補助に留まる。実際の境界はmutation lockとreview lock
- reviewerが固定base/headを読めるのはreviewが実行中の間に限る。reviewが終わればfreezeが外れ、reviewerは全shellを拒否される
- commit subjectの文言規約、再指摘の意味的同定は機械保証しない
