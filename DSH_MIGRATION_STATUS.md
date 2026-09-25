# DSH main profile bundle 完了報告

`dsh/` の DSH `0.1.7-rc.1` 移行の現状。検証は`cd dsh && npm test`（静的検証・unit suite・実DSH E2Eを1回で通す）。

## 完了条件の状況

| 条件 | 状態 |
|---|---|
| `npm run verify`が成功 | 成功（`verify.mjs`がunit suiteとE2Eを順に実行） |
| 実DSH profileの起動が成功 | 成功（E2Eが一時`DSH_HOME`へinstallして実際に起動） |
| mock providerを使った4 workflowのE2Eが成功 | 成功（外部APIへ接続せず課金requestなし） |
| skillsの発見とloadが成功 | 成功（workspaceにskill rootを置かず、bundle providerだけを検証） |
| slash commandが実際のWeb／command経路で成功 | 成功（turnが開いていない状態から`ctx.commands.execute`でdispatch） |
| hook責務表と実装・テストが一致 | 一致（`test/hook-responsibilities.test.js`が表の全行を実装へ照合） |
| policy欠落・初期化失敗がfail-closed | 実装済み（必要service 5件の欠落、state破損、route組重複、指示file欠落で起動失敗） |
| 金額・予算設定が存在しない | 満たす（`test/bundle-hygiene.test.js`と`verify.mjs`が検査） |
| Git worktreeが意図した変更だけ | 未達成。`git add`／`git commit`がこのsessionの承認無効化により実行できない |
| 変更を1ファイル1コミットで記録 | 未達成。同上 |

## 実装した欠陥修正

1. **slash commandのWeb経路**（`index.js`）
   Web composerは`input.hint`を宣言したcommandをleadingInputとしてclaimし、`ctx.commands.execute`へ渡す。この経路はturnを開かないため、旧実装の「turnが無ければ拒否」は全commandを失敗させていた。handlerが`agent.followup`でtask本文とrouting intent contextを配送し、`agent/pre-step`が配送turnへintentを束縛する形に変更した。

2. **route roleの解決不能**（`lib/policy.js`、`cordis.patch.yml`）
   plannerとcoderが同じ`zai`/`glm-5.3`を宣言していたため、`routeFor`が必ずplanner側を返し、coderのroleが解決不能だった。coderのguardはすべて「許可すべき仕事を拒否」していた。coderへ`glm-5.3-code`という別idを与え、`assertRouteCommandConsistency`が組の重複を起動時に拒否するようにした。`test/route-identity.test.js`がpatchとroute tableの一致を強制する。

3. **skill sourceが保護されていなかった**（`lib/policy.js`）
   `deny-skill-source.sh`の責務が未移植だった。`PROTECTED_COMPONENTS`へ`skills`を追加し、skill本文の書換えを構造化write・shell・`git add`のすべてで拒否する。

4. **E2Eがproduction経路を検証していなかった**（`test/e2e/*`）
   旧E2Eは配布元`skills/`をworkspaceの`.agents/skills`へcopyしてからcatalogを検査していた。DSHの探索rankはproject-agents=200 < bundle provider=350なので、copyした側が必ず勝ち、bundleのproviderは一度も評価されなかった。copyを廃止し、workspaceにskill rootを置かないことを明示的に検査する。

5. **E2Eが外部roleの境界を検証していなかった**（`test/e2e/probe-plugin.mjs`）
   coder自身のwrite・allowedCommands・Git・sandbox拡張、reviewerのwrite・test・network・別model起動、critical finding後の第二reviewer不在を追加した。roleは`agent.options`のprovider/model組から解決されるので、probeはroute tableから組を取ってそのroleのagentを構築する。

6. **指示文の二重管理**（`AGENTS.dsh.md`、`lib/dsh-instructions.js`）
   本文を`AGENTS.dsh.md`だけに置き、`lib/dsh-instructions.js`はmarker間を読むだけにした。読み取り失敗・marker欠落・空blockは起動失敗にする。

7. **installのstale化**（`test/e2e/harness.mjs`）
   pnpmは`file:`依存へ`Already up to date`を返すことがあり、profileが古い版を配り続ける。E2Eはinstall済みcopyを消してから入れる。

## 追加した回帰test

- `test/route-identity.test.js` — patchとroute tableの組一致、組の重複不在
- `test/hook-responsibilities.test.js` — 責務表の全行と純粋述語・必要serviceの一致
- `test/skill-classification.test.js` — 配布skillのfrontmatterと`SKILL_CLASSIFICATION.md`の一致
- `test/instructions.test.js` — 指示文の単一source性とfail-closed
- `test/e2e-modules.test.js` — E2E harnessとprobeの読み込み・export・禁止credential参照
- `test/bundle-hygiene.test.js` — 一時fileの不在と公開entryの存在
- `test/working-tree.test.js` — install後にworking treeのfileを編集できること（hard link解消）
- `test/clean.mjs` — `pretest`で一時fileを掃除（runnerがglobを先に展開するため）

## 未達とその理由

- **変更のcommit**: このsessionで承認promptが無効化されており、`git add`／`git commit`はsandbox escalationを要求するため実行できない。worktreeは意図した変更だけになっている（下記file一覧）。commitは利用者の操作が必要。
- **reviewerのpinned rangeのE2E**: reviewのfreezeはtool callの実行中だけ存在する。freeze中のreviewerのverdictは`tools.guard`の段では読めず（reviewが未dispatchのため）、dispatch中の並行readも安定しない。規則自体は`reviewGitCommandAllowed`のunit testで網羅し、E2Eはfreezeが無い状態のreviewerが全shellを拒否されることと、reviewが実行されたことを検証する。

## 未追跡fileの扱い

- `dsh/test/apply-route-ids.mjs`はroute idをpatchへ適用するための一時scriptで、`test/route-identity.test.js`が同じ修正を行うため不要。削除は`npm test`の`pretest`（`test/clean.mjs`）が行う。
- このfile（`DSH_MIGRATION_STATUS.md`）は調査記録であり配布物ではない。不要なら削除してよい。
