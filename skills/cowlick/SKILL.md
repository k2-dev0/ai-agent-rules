---
name: cowlick
description: "meeting から draft または apply mode で呼ばれ、確定要件から未承認の設計ドラフトを作るか、ponytail 後に最終承認された同一 revision を @.[agent_name]/prompt/ へ正式反映する"
allowed-tools: Read, Write, Edit, Bash, Agent
user-invocable: false
---

## 目的

確定要件から設計ドラフトを作る責務と、承認済みドラフトを固定経路で正式反映する責務を持つ。
要件監査、ユーザーへの質問、設計の単純化、最終承認は meeting が統括する。

## 実行フロー

### Step 1: mode を確定する

meeting から渡された先頭引数を mode として使う。

- `draft`: `preflight_ready` の要件 revision から未承認ドラフトを作る
- `apply`: ponytail 後に最終承認された draft revision を正式反映する

mode がない、または上記以外なら何も変更せず `invalid_mode` を meeting へ返す。

### Step 2: draft mode で初期ドラフトを作成する

`draft` mode では、同じ要件 revision に対する preflight の `preflight_ready` が現在の会話にあることを確認する。結果がない、対象範囲が変わった、または重大な論点が未回答なら何も作らず `preflight_required` を返す。

preflight が付けた **明示要件**、**禁止・制約**、**受入済み trade-off**、**既存制約**だけを設計上の固定条件として使う。**設計選択**は候補であり、そのまま要件へ昇格させない。禁止された手段に関連する別手段を、積極要件へ読み替えない。

`draft-prompt/` が既に存在する場合は、現在の要件 revision に対する直前の draft revision だと会話から確認できる場合だけ Edit で更新する。別要件の残骸、所有者不明、または対応する revision がない場合は一切触れず `draft_conflict` を meeting へ返す。

整理された要件を元に、[agent_name]がプロンプトの初期ドラフトを作成する。この時点では未承認であり、`.[agent_name]/prompt/`へ反映しない。

設計書へ分割する前に、全体の既存実行経路と新設予定の実行・永続化・運用境界を一列に並べる。preflight の「境界を新設しない基準案」と比較し、基準案が要件を満たすならそれを初期ドラフトにする。新しい public endpoint、queue、scheduler、worker、serverless function、外部接続、global/shared 変更は、基準案が満たせない明示要件または既存制約がある場合だけ追加する。

ドラフトは「後述の構成の一式」を **プロジェクトルートの `draft-prompt/`** に作る（`.prompt.md` + `branch-<機能名>-prompt.md` × N）。
存在しなければ、プロジェクトルートから次のコマンドを単独で実行する。Codexではworkspace sandbox内の通常のディレクトリ作成として扱うため、承認を要求しない。shell wrapperや他commandとの連結へ書き換えない。

```bash
mkdir -p draft-prompt
```

ディレクトリの中身はこの 2 種類だけにすること。メモや作業ファイルを同居させると Step 5 のスクリプトが弾く。

- Why: ユーザーがレビューする対象なので、エディタでそのまま開ける場所に置く。セッションの一時領域（scratchpad / `$TMPDIR`）はパスが不規則でユーザーが確認しづらい
- Why: `.[agent_name]/` は sandbox の denyWrite で保護されておりエージェントは直接書き込めない。`draft-prompt/` は保護対象外なので通常の Write / Edit で往復でき、保護領域への書き込みは Step 5 の固定スクリプト 1 回に集約される
- `draft-prompt/` は Step 5 でスクリプトが畳むまでの一時的な置き場。**コミットしてはならない**（`git add` の対象に含めない。恒久的に無視したいならプロジェクトの `.gitignore` に足すのはユーザーの判断）
- ドラフトの改訂は **Edit** で行う。既存ファイルへの Write（全上書き）は `overwrite.sh` が ask に倒すため、レビュー往復のたびに承認プロンプトが出る（新規作成の Write は素通りするので初回作成はそのままでよい）

### Step 3: draft mode でコードベース調査を委任する

各設計書の初期ドラフトを、固定実行器の`research`モードへ1枚ずつ渡す。

```
bash [skills_root]/deepseek/delegate.sh research \
  --hard-timeout-minutes <総待機分> \
  --idle-timeout-seconds <無通信秒> \
  --poll-seconds <確認間隔秒> \
  <task-id> draft-prompt/branch-<機能名>-prompt.md
```

- 各実行前に、設計書の調査範囲と難易度からtimeoutと確認間隔の3値を決め、値と理由を明示する。再試行でも固定値を惰性で再利用せず、改めて明示する
- DeepSeekは読み取り専用とし、コード、テスト、設計ドラフトを変更させない
- 調査結果は`file:line`の根拠、不明点、設計リスクとして返させる
- 各設計書について、設計書ごと削除できる既存経路、新しいendpointやruntime resourceを使わない入口、既存のdeployment・scheduling・failure recovery patternを探させる
- ドラフトの新設要素が別の新しい失敗モードと緩和策を生んでいる場合は、原因側と緩和策をまとめて消せる反証を探させる
- [agent_name]が重要な根拠を実ファイルで再確認する。DeepSeekの自己申告だけで設計へ採用しない
- 接続失敗、timeout、最終応答欠落などの応答失敗では、新しいtask-idで固定実行器を1回だけ再試行する。2回続けて失敗したら、上位モデル相当のAgent / subagentを読み取り専用で優先し、使えなければ[agent_name]自身が調査を引き継ぐ
- API key欠落、HTTP 401、invalid API key、authentication failedなど明示的な認証失敗では再試行せず、直ちに同じ上位モデルの代替経路へ切り替える。予算超過、ZDR対応先なし、依存command欠落、参照先欠落は応答失敗に数えず、理由と未調査範囲を含む `research_blocked` を meeting へ返す

DeepSeekと代替subagentはコードベースの探索と根拠収集だけを担当する。調査結果を踏まえた設計判断とドラフト更新は、必ずオーケストレーターである[agent_name]が行う。要件 revision と異なる判断が必要ならユーザーへ直接質問せず、選択肢、挙動差、推奨を含む `consultation_required` を meeting へ返す。

調査を反映した後、全設計書をもう一度横断して、新設境界とglobal/shared変更のそれぞれが明示要件または既存制約へ直接対応していること、境界を新設しない基準案では満たせない根拠があることを確認する。設計選択同士の依存だけで必要性を説明している要素を残さない。

この横断確認を満たし、未決定事項がなければ、対象ファイル名と内容で識別できる draft revision とともに `draft_ready` を返して停止する。ponytail、最終承認、正式反映へ続けて進まない。

### Step 4: apply mode の前提を確認する

`apply` mode では、次をすべて確認する:

1. ponytail が現在の draft revision に `ponytail_ready` を返している
2. ユーザーの最終承認が同じ draft revision に対するものである
3. 最終承認後に `draft-prompt/` のファイル名または内容が変わっていない

一つでも確認できなければ正式反映せず、`ponytail_required` または `approval_required` を meeting へ返す。古い承認を推測で流用しない。

### Step 5: apply mode でドラフト一式を @.[agent_name]/prompt/ へ移す

Step 4 を満たした場合だけ、専用スクリプトでドラフトを反映する。**引数は取らない** — 移動元（`draft-prompt/`）・宛先（`.[agent_name]/prompt/`）・受け入れるファイル名（`.prompt.md` と `branch-<機能名>-prompt.md`）がすべてスクリプト内に固定されているため、サンドボックス外実行の事前 allow はこの経路 1 本に限定される。

```
bash [skills_root]/cowlick/apply-prompt.sh
```

- スクリプトは反映前に「中身が index と設計書だけか」「index が並べた設計書と実体が 1:1 で対応するか」を検証し、1 つでも外れたら宛先に触れずに終了する
- 全件の反映に成功したら `draft-prompt/` をスクリプトが畳む。ユーザーが `rm` を承認する必要はない
  - Note: 消せるのは固定パスの `draft-prompt/` と、そこにある検証済みの index / 設計書だけ。**引数を受け取らないため削除先を外から動かせず**、`rm` の ask ゲートを迂回する任意ファイル削除の抜け道にならない。この性質を壊すので、後からドラフトのパスを引数で受け取れるようにしてはならない
  - `rmdir` で畳むため、想定外のファイルが残っていればディレクトリは消えずに警告が出る（再帰削除で巻き込むことはない）
- 前タスクの `branch-*-prompt.md` が宛先に残っていた場合は、今回の一式に無いものだけをスクリプトが削除する
  - Why: 残骸があると index と実体が食い違い、conductor が前タスクの設計書を実装してしまう

- Claude Code では本スクリプトは `settings.json` の `sandbox.excludedCommands` に登録済みのため、そのまま実行すれば最初から sandbox 外で走る（sandbox 内では denyWrite の `.[agent_name]` に阻まれて必ず失敗する）
  - `excludedCommands` と事前 allow はコマンド文字列の照合で決まるため、必ずプロジェクトルートから**上記の 1 行をそのまま単独で**実行すること。以下はいずれも照合を外し、sandbox 内実行の失敗と承認プロンプトを復活させる
    - 絶対パスにする / `./` の有無を変える / `bash` を `sh` に変える — パスは正規化されず、文字列が違えば別のコマンドとして扱われる
    - `cd ... &&` を前置する、`&&` `;` `|` で他のコマンドと繋ぐ — 複合コマンドは区切り文字で分割され、**各サブコマンドが個別に**照合される。繋いだ相手が許可されていなければプロンプトが出る
    - `> log 2>&1` などのリダイレクトを付ける — リダイレクト先の解決可否によってはプロンプトに倒れる
- 「Operation not permitted」で失敗した場合は、まず呼び出しが上記の相対パス形式かを確認し、違っていれば形式を直して再実行する。相対パス形式でも失敗する場合のみ `excludedCommands` 未設定の古い配置と判断し、sandbox を無効化して再実行のうえ `settings.json` の更新をユーザーに案内すること
- Codex では `distributed` permission profile が `.codex` を保護し、`.codex/rules/default.rules` が `bash .agents/skills/cowlick/apply-prompt.sh` だけを sandbox 外で allow する。失敗時は迂回せず、project の信頼と rules 配置を確認すること

## 成果物の構成

成果物は「実装順の index 1 枚」と「1 機能 = 1 枚の設計書」で構成する。以下の形式は任意ではなく必須とする。

| ファイル | 役割 |
|---|---|
| `.prompt.md` | 実装順の index。**実装順のリストだけ**を書き、設計の中身は書かない |
| `branch-<機能名>-prompt.md` | 機能 1 つ分の設計書。index に並べた数だけ作る |

- Why: 構成を書き手の裁量に任せると、使用するモデルや reasoning effort によって出力の粒度が大きくブレる。形式を固定し、どのモデルが書いても同じ粒度の設計書になるようにする
- Why: 巨大なタスクでも文章の要約なら数十行に収まってしまい、最終的な実装規模が読めない。設計書の枚数と Changes の行数が、そのままタスク規模の見積もりとして機能するようにする
- Why: 設計書をファイルとして分けることで、conductor が 1 枚だけ読んで 1 枚だけ実装できる。index のチェックボックスがそのまま進捗になる

### 機能名の付け方

`branch-` 接頭辞のとおり、機能名は **そのまま git のブランチ名に使える ASCII の kebab-case** とする（`user-address-api` など）。
日本語や `_` / 大文字始まりは apply-prompt.sh が弾く。

### 「1 機能」の粒度

設計書 1 枚に収める「1 機能」は rebase スキルの分類基準と揃える（設計書 1 枚 ≒ 1 ブランチ ≒ squash 後の 1 コミット）:

- api とバリデーションスキーマは同一の 1 枚
- コンポーネントは 1 コンポーネントで 1 枚
- マイグレーションファイルとスキーマ変更は同一の 1 枚
- ヘルパー関数・定数への置き換えは、置き換え先の変更と同一の 1 枚
- テスト（`*.test.*`）は対象実装と同一の 1 枚（独立した設計書にしない）

### index（.prompt.md）のテンプレート

実装順に並べたチェックリストのみ。**設計の中身は一切書かない。** 全項目を `- [ ]`（未実装）で作る。

```markdown
# 実装順

- [ ] branch-user-address-api-prompt.md
- [ ] branch-user-address-form-prompt.md
```

- 並び順 = 実装順。依存がある場合は依存される側を先に置く
- `- [ ] <ファイル名>` 以外の形式で書くと apply-prompt.sh が弾く（見出しや説明文の行は自由）
- `[x]` に倒すのは conductor の仕事。cowlick では全件 `[ ]` で出す

### 設計書（branch-<機能名>-prompt.md）のテンプレート

Summary / Changes / 対象ファイル / 参照ルール / 完了条件 のセクションを必ず持つ。

- **Summary**: この機能で何をするかを 1〜2 行で書く
- **Changes**: 具体的な変更内容を、後述の疑似コード形式の文章で書く
- **完了条件**: 各設計書に持たせる（conductor は 1 枚だけ読んで 1 枚だけ実装するため、1 枚で自己完結させる）

### Changes の書き方

処理の流れをコードの形で書き、中身を日本語の文章で埋める疑似コード形式とする。

1. 予約語・構文キーワード・ライブラリ API 名は英語のまま書く（import / export / function / const / let / if / for / async / await / $transaction / Promise.all など）
  - Why: 実装時に必ずその単語になるものを日本語に翻訳しても情報は増えない。逆に英語のまま残すことで「どの構文・API を使うか」という設計判断が Changes の時点で確定する
2. 分岐・ループは「〜の場合は」と文章で流さず、`if (...) { }` `for (...) { }` の構文で書き、条件と処理内容だけを日本語にする
  - Why: 分岐・ループの数がそのまま Changes の行数に現れることで、実装規模の見積もりが機能する
3. 関数名・引数名・処理の説明は日本語の文章で書く（実装時の英語命名はエージェントに委ねる）
4. エラー処理・副作用（DB 書き込み、メール送信、外部 API 呼び出し等）は省略せず 1 つずつ書く。行数を節約するための要約は禁止する
  - Why: ここで省略した処理は実装時にモデルの裁量で補われ、成果物がブレる

### 記入例

住所変更機能を API とフォームの 2 機能に割った場合、`draft-prompt/` は次の 3 ファイルになる。

**draft-prompt/.prompt.md**

```markdown
# 実装順

- [ ] branch-user-address-api-prompt.md
- [ ] branch-user-address-form-prompt.md
```

**draft-prompt/branch-user-address-api-prompt.md**

````markdown
# 住所変更 API

## Summary

マイページからユーザー自身の住所を変更できる API を追加する。

## Changes

```typescript
// user-address-api.ts
export function ユーザーの住所を変更する関数(ログイン中のユーザーデータ, 変更後の住所) {
  ログインチェックを行う

  for (登録済みの住所 of ユーザーの住所一覧) {
    if (渡された住所と重複している) {
      API エラーを返す
    }
  }

  $transaction {
    User テーブルの address カラムに渡された住所を書き込む
  }

  書き込みが成功したらユーザーのメールアドレスに住所変更完了のメールを送付し、
  クライアント側に 200 を返す
}
```

## 対象ファイル
- @front/features/mypage/resources/user/user-address-api.ts
- @front/features/mypage/resources/user/schema.ts

## 参照ルール
- @.[agent_name]/rules/typescript/api-pattern.md
- @.[agent_name]/rules/typescript/validation-pattern.md

## 完了条件
- Changes に書かれた処理が実装されていること
- 型エラー、フォーマットエラーがないこと
````

**draft-prompt/branch-user-address-form-prompt.md**

````markdown
# 住所変更フォーム

## Summary

マイページに住所変更フォームのコンポーネントを追加する。

## Changes

```typescript
// UserAddressForm.tsx
export function 住所変更フォーム(現在の住所) {
  const 入力中の住所 = フォームの状態として保持する

  送信ボタン押下で住所変更 API を呼び出す

  if (API がエラーを返した) {
    フォーム下部にエラーメッセージを表示する
  }

  成功したら完了トーストを表示する
}
```

## 対象ファイル
- @front/features/mypage/resources/user/components/UserAddressForm.tsx

## 参照ルール
- @.[agent_name]/rules/typescript/ui-pattern.md

## 完了条件
- Changes に書かれた処理が実装されていること
- 型エラー、フォーマットエラーがないこと
````
