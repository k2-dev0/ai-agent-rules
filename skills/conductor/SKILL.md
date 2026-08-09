---
name: conductor
description: "旧run-agentとして、@.[agent_name]/prompt/ の承認済み設計書を1枚選び、DeepSeekが本体コードとPrisma schemaの初回実装、CodexまたはClaudeがテスト・レビュー・修正を担当するTDDフローを実行し、最終報告前にpolish品質ゲートを必ず完了させる"
allowed-tools:
  - Read
  - Bash
  - Agent
  - Skill(polish)
disable-model-invocation: true
---

## 目的

[agent_name]を唯一のオーケストレーターとして、未実装の設計書を1枚だけ完了する。DeepSeekが許可済み本体コードと`schema.prisma`の初回実装候補を作り、[agent_name]はテスト、採否、反映後の修正、検証、Gitを担当する。

旧`run-agent`の責務は現在の`conductor`が引き継いでいる。

## 前提

`cowlick`が次を配置済みで、ユーザーの本スキル呼び出しを実行指示として扱う。

| ファイル | 役割 |
|---|---|
| `.prompt.md` | `- [ ] branch-<機能名>-prompt.md`形式の実装順index |
| `branch-<機能名>-prompt.md` | ユーザー承認済みの設計書 |

## 実行フロー

### 1. 対象を1枚だけ選ぶ

`@.[agent_name]/prompt/.prompt.md`の最初の`- [ ]`を選ぶ。飛ばしたり順序を再判断したりしない。

- 未実装がなければ、全設計書が完了済みと報告して終了する
- indexがない、空、参照先がない場合は終了する
- 他の設計書は読まない

### 2. 変更範囲を確定する

設計書の対象ファイルを、テスト資産、DeepSeekへ渡す本体コードと`schema.prisma`、その他の保護対象へ分類する。次は[agent_name]管理のため委任しない。

- test/spec、fixture、factory、mock、stub、fake、snapshot
- Markdown、AGENTS.md、スキル、エージェント設定
- package、lockfile、CI、migration、環境設定
- Git管理ファイル

DeepSeekへ渡す許可パスに未コミット変更があれば、ユーザー変更との衝突として停止する。

### 3. tddをフル実行する

コード変更を伴う場合は`tdd`へ従う。

1. [agent_name]がテストシナリオを提案し、ユーザーの一括承認を得る
2. [agent_name]がテストを書き、追跡対象ならファイル単位で即コミットする。無視されたテスト資産は強制stageせず、作業ツリー上で検証して継続する
3. [agent_name]がRedを確認する
4. 固定実行器でDeepSeekへ本体コードと`schema.prisma`の初回実装を委任する
5. [agent_name]が候補パッチを検証し、追跡対象を1ファイルずつ反映・即コミットする。無視されたファイルは作業ツリー上で検証する
6. 候補反映後に[agent_name]がGreen、レビュー、必要な本体コード修正を直接完了する

[agent_name]はDeepSeekの最初の応答前に、本体コードや`schema.prisma`のstub、雛形、部分実装を作ってはならない。接続失敗、timeout、最終応答欠落などで候補を取得できなければ、新しいtask-idと明示的に選び直したtimeout / pollで1回だけ再委任する。2回続けて応答に失敗した場合、または明示的な認証失敗があった場合だけ、上位モデルが初回実装を引き継ぐ。上位モデル相当のAgent / subagentを利用できるなら許可パス限定で優先し、使えなければ[agent_name]自身が実装する。候補が返った後のレビュー、採否、修正は[agent_name]の責務であり、DeepSeekへ再委任しない。

調査・ドキュメントだけの設計書は[agent_name]が通常どおり実行し、DeepSeek実装を呼ばない。

### 4. DeepSeekの相談を処理する

DeepSeekはテストの穴を[agent_name]へ相談できるが、テスト・設計を変更できない。[agent_name]が検証し、既存の承認内容で一意に解決できなければ、次へ進まずユーザーへ新しいシナリオまたは設計変更を提示する。

相談を解決して再委任するときは、結果ディレクトリの衝突を避けるため新しいtask-idを使う。

### 5. 完了を検証し、最終品質ゲートを通す

設計書の完了条件、対象・回帰テスト、型検査、lint、レビュー、ファイル単位コミットを確認する。DeepSeekの自己申告だけで完了扱いしない。

この確認の直後、index更新と最終報告の前に `polish` を自動で実行する。機能名と、この設計書で変更してコミットした追跡済み本体コードの相対パス一覧を必ず渡す。`polish` はその一覧を DeepSeek のネスト検出へ渡すため、上位モデルが改めて差分探索して対象を補完してはならない。`polish` の品質ゲートが完了しなければ、index更新と最終報告へ進まない。

- `polish` が変更した場合は、対象テスト・型検査・lint・レビューをやり直し、追跡対象の変更をコミットしてから次へ進む
- 品質ゲートが残した候補や根拠は、`polish` の結果として受け取り、未解決のまま完了扱いにしない
- `polish` が完了後に返す機能名で、品質ゲートの receipt を記録する。記録できなければ次へ進まない

```bash
bash [skills_root]/polish/quality-gate.sh record <機能名>
```

### 6. indexを完了へ変更する

すべて満たし、同じ機能名・現在の HEAD の `polish` receipt が記録済みの場合だけ固定スクリプトを実行する。スクリプト自身も receipt を再検証するため、記録のない状態で `[x]` へ進めない。

```bash
bash [skills_root]/conductor/mark-prompt-done.sh <機能名>
```

`<機能名>`は`branch-`と`-prompt.md`を除いた部分とする。既に`[x]`なら対象取り違えとして停止する。スクリプトのパスや呼び出し形式を変えず、複合コマンドにしない。

Codexでは`.codex/rules/default.rules`、Claude Codeでは`settings.json`がこの固定コマンドだけをsandbox外で許可する。失敗したら迂回せず、project trustと配置済み設定を確認する。

### 7. 報告して停止する

次を報告し、次の設計書へ自動で進まない。

- 実装した設計書と機能名
- 承認されたテストシナリオ
- DeepSeekの初回実装・ネスト検出のtask-id、相談、候補パッチの採否
- Red、Green、回帰確認
- polish の品質ゲート結果
- 積んだコミット
- indexの残件数

設計書1枚を1ブランチ・1PRの単位とし、続きはユーザーが改めて`/conductor`を呼ぶ。

## DeepSeek固定実行器

```bash
# 読み取り専用調査
bash [skills_root]/deepseek/delegate.sh research \
  --hard-timeout-minutes <総待機分> \
  --idle-timeout-seconds <無通信秒> \
  --poll-seconds <確認間隔秒> \
  <task-id> <設計書>

# 隔離worktreeで本体コードとschema.prismaの初回実装候補を作成
bash [skills_root]/deepseek/delegate.sh implement \
  --hard-timeout-minutes <総待機分> \
  --idle-timeout-seconds <無通信秒> \
  --poll-seconds <確認間隔秒> \
  <task-id> <設計書> <許可する本体コードまたはschema.prisma>...

# OpenCode・OpenRouter・対象モデルへの疎通だけ確認
bash [skills_root]/deepseek/delegate.sh smoke
```

各委任の直前に、調査範囲、実装範囲、難易度から3つの時間値を選び、値と理由を明示する。再試行でも改めて選択を明示し、固定値を惰性で使い回さない。

実行器はOpenRouterの対象期間使用量38 USDで停止し、API keyに40 USD以下の月次またはリセットなしhard limitがあることを検証する。ZDRと`data_collection: deny`をリクエストでも強制し、OpenCodeの外部プラグインを無効化する。

`smoke`は従量課金のリクエストなので、通常の回帰テストでは実行せずデフォルトでスキップする。疎通確認が必要な場合も、実行するかスキップするかをユーザーへ一度だけ質問し、明示的に実行を選んだ後だけ呼ぶ。固定promptの`hello`だけを送り、下位モデルのtool権限をすべて拒否し、応答は一時領域から外へ残さない。CodexのrulesとClaude Codeのpermissionも、このmodeだけを毎回確認へ倒す。
