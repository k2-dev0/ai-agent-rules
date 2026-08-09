---
name: tdd
description: 承認済み設計を、シナリオ一括承認を唯一の通常ゲートとしてTDD実装する。DeepSeekが本体コードとPrisma schemaの初回実装、[agent_name]がテスト・レビュー・候補反映後の修正を担当する。
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/require-test.sh
---

## 目的

[agent_name]を設計・テスト・レビュー・修正の責任者、DeepSeekを制限された初回実装担当として、`scenario → red → delegated-green → review-green`を連続実行する。

## 権限境界

| 対象 | [agent_name] | DeepSeek |
|---|---|---|
| テストシナリオ提案 | 可 | 相談として提案のみ可 |
| テスト資産の変更 | 承認済みシナリオ内だけ可 | 禁止 |
| 設計資産の変更 | cowlickの承認後だけ可 | 禁止 |
| 許可された本体コードと`schema.prisma`の初回実装 | DeepSeekの2回連続応答失敗または認証失敗後だけ可 | 可 |
| DeepSeek候補反映後の本体コード修正 | 可 | 禁止 |
| テスト実行・レビュー・Git | 可 | 禁止 |

テスト資産には、test/spec、fixture、factory、mock、stub、fake、snapshot、golden file、テスト設定、CI上のテスト実行設定を含める。

## 通常ゲート

通常のユーザー承認は、実装前の**シナリオ一括承認**だけとする。各シナリオについて前提、操作、期待結果を提示する。承認後、具体的なテストコードは[agent_name]が自動で作る。

次はシナリオ変更なので再承認する。

- 期待結果または前提条件を変える
- シナリオを追加、削除、統合する
- 検証対象の責務や公開挙動を変える

承認済みシナリオを忠実に表すためのimport、型、構文、テスト構造の修正は再承認しない。

## 実行フロー

### 1. シナリオを承認する

設計書と関連コードを読み、正常系、境界値、異常系、副作用、回帰リスクをまとめて提示する。承認されるまでファイルを変更しない。

### 2. [agent_name]がテストを書く

承認済みシナリオだけをテストへ変換する。追跡対象のファイルは1ファイルずつ即コミットする。無視されたテスト資産は `git add -f` / `git add --force` を使わず、作業ツリーに残して検証と後続工程を継続する。テストの意味を変えるために既存assertionを弱めてはならない。

### 3. Redを確認する

対象テストをプロジェクトのtest script経由で実行し、実装不足または期待値との差で失敗することを確認する。

- syntax/import/typeの失敗は、シナリオを変えず[agent_name]が修正する
- 最初からGreenなら、テストが要求を検出できるか検証する
- テスト自体またはシナリオの変更が必要なら再承認へ戻る

### 4. DeepSeekへ初回実装を委任する

共通のDeepSeek委任実行器を使い、設計書と変更可能な本体コードまたは`schema.prisma`の相対パスだけを渡す。テスト結果の要約は[agent_name]が指示へ含める。

```bash
bash [skills_root]/deepseek/delegate.sh implement \
  --hard-timeout-minutes <総待機分> \
  --idle-timeout-seconds <無通信秒> \
  --poll-seconds <確認間隔秒> \
  <task-id> <設計書> <許可する本体コードまたはschema.prisma>...
```

委任前に、変更範囲、実装量、難易度から総待機時間、無通信timeout、確認間隔を決め、3値と理由を明示する。DeepSeekは隔離worktreeで初回実装の候補パッチを作る。シェル、Git、外部通信、テスト・設計・設定の編集は許可しない。

[agent_name]は候補反映前にstub、雛形、部分実装を作らない。接続失敗、timeout、最終応答欠落などで候補を取得できない場合は、新しいtask-idと明示的に選び直したtimeout / pollで1回だけ再委任する。2回続けて応答に失敗した場合は上位モデルが初回実装を引き継ぎ、上位モデル相当のAgent / subagentを利用できるなら許可パス限定で優先し、使えなければ[agent_name]自身が実装する。API key欠落、HTTP 401、invalid API key、authentication failedなど明示的な認証失敗では再試行せず、直ちに同じ上位モデルの代替経路へ切り替える。予算超過、ZDR非対応、依存command欠落は応答失敗に数えず停止する。

### 5. 相談を処理する

DeepSeekがテストの穴、矛盾、曖昧さ、偽陽性・偽陰性を報告したら[agent_name]が根拠を検証する。

- 既存の承認内容から一意に解決できる: [agent_name]が回答し、新しいtask-idで再委任する
- 非ブロッキングな改善案: 記録して実装を継続する
- 新しい設計判断またはテストシナリオが必要: ユーザー承認へ戻る

DeepSeekには発言権だけを認め、テスト・設計の編集権と決定権は与えない。

### 6. 候補パッチを検証して反映する

`result.json`、`opencode.jsonl`、`candidate.patch`を読む。自己申告ではなく実際のパッチを正とし、次を確認する。

- 変更が許可パス内だけである
- テスト資産、設計、設定、Gitを変更していない
- テスト環境検出、値のハードコード、assertion攻略がない
- 承認済み設計とシナリオに一致する

候補が返った後の採否は上位モデルのレビュー責務である。安全に修正できる問題なら、候補を土台に[agent_name]が直接直す。許可外変更や設計逸脱でパッチ全体を拒否しても、DeepSeekへレビュー・修正を戻さず、[agent_name]が承認済み設計の範囲で実装を完成させる。問題がなければ追跡対象を1ファイルずつ反映して即コミットする。無視されたファイルは作業ツリー上で検証し、強制stageはしない。

### 7. [agent_name]がGreen・レビュー・修正を完了する

対象テスト、関連回帰テスト、必要な型検査とlintを実行する。DeepSeek候補を反映した後は、[agent_name]が差分をレビューし、承認済み設計へ合わせる本体コード修正を直接行う。通常の修正をDeepSeekへ再委任しない。テストまたは設計を変える必要が出た場合だけ承認フローへ戻る。

## 例外停止

次の場合は正常な自動区間を停止する。

- OpenRouterの対象期間使用量が38 USD以上、またはAPI keyの上限が40 USD超
- ZDR対応エンドポイントが利用できない
- OpenCode、API key、依存コマンドがない
- DeepSeekが許可外パスを変更した
- ユーザーの未コミット変更と対象パスが衝突する
- 2回の応答失敗後も上位モデルの実装経路を利用できない
- DB、依存関係、公開APIなど承認範囲外の変更が必要になる

## 完了条件

- 承認済みシナリオがすべてGreen
- 関連回帰テスト、型検査、lintが必要な範囲で成功
- [agent_name]が差分をレビュー済み
- 追跡対象の変更が1ファイルずつコミット済み
- 無視された対象変更は作業ツリー上で検証済みで、未コミットである理由を完了報告に含めた

Red、Green、DeepSeekの相談、採否理由、使用したtask-idを完了報告へ含める。
