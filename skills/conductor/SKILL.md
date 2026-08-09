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

コード変更では`tdd`を省略せず、シナリオ一括承認、test作成とRed、DeepSeek候補、上位モデルのレビュー・修正とGreenまで完了する。追跡対象は1ファイルずつ即コミットし、無視されたテスト資産は強制stageせず作業ツリーで検証する。

変更対象が`schema.prisma`だけなら`tdd`のschema例外に従い、シナリオ、test作成、Red/Greenを要求せず、Prismaのformat、validate、generateで検証する。本体コードを同時に変更する場合、その公開挙動は通常の`tdd`から除外しない。

DeepSeekを呼ぶ前に`../deepseek/DELEGATION.md`を全文読む。[agent_name]は最初の応答前に本体コードや`schema.prisma`のstub、雛形、部分実装を作らず、候補返却後のレビュー、採否、修正をDeepSeekへ戻さない。

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
