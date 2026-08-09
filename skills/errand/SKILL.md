---
name: errand
description: "ユーザーが $errand を明示して、既存パターンの反復で一意に決まる小さな本体コード修正・定型ファイル追加・Prisma schema追加の初回実装を、設計書なしでDeepSeekへ委任したいときだけ使う。DeepSeek候補の反映後はCodexまたはClaudeが修正する。複数ファイルを扱えるが、新機能設計、要件判断、設定・migration・依存関係の変更には使わない。"
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, Agent
disable-model-invocation: true
---

## 目的

設計書を作る価値がないほど小さく、依頼と最寄りの既存パターンから変更内容・対象パス・完了条件を一意に確定できる実装だけを委任する。既存パターンから配置・内容が一意な定型ファイルとPrisma modelの追加を含める。DeepSeekが依頼された変更の初回実装候補を作り、上位モデルは要件の縮約、許可パスの決定、候補パッチの採否、反映後の修正、検証、Gitを担当する。

## 初回実装と修正の境界

- 初回実装とは、このerrandで依頼された挙動について許可パスへ最初に加えるコード変更を指す。新規ファイルだけでなく既存ファイルへの機能追加も含む
- 初回実装はDeepSeekの`candidate.patch`から始める。上位モデルが最初の応答前にstub、雛形、部分実装、手作業の代替実装を作ってはならない
- DeepSeek候補を許可パスへ反映した後は、上位モデルがレビュー、テスト、型検査、lintの結果に基づいて本体コードを直接修正する。修正をDeepSeekへ再委任しない
- 候補が未生成、timeout、最終応答欠落なら新しいtask-idで1回だけ再委任する。2回続けて応答に失敗した場合、または明示的な認証失敗があった場合だけ、上位モデルが初回実装を引き継ぐ
- 候補が返った後の修正する／しない、部分採用、全体拒否の判断は上位モデルが行う。パッチ全体を拒否してもレビュー・修正をDeepSeekへ戻さず、承認済み範囲を上位モデルが完成させる

## 起動境界

ユーザーが明示的に errand を呼んだ場合だけ使う。通常の自然言語依頼から自動起動してはならない。meeting / cowlick / ponytail は呼ばない。

次のいずれかなら、変更せず理由を報告して停止する。meeting を自動で起動してはならない。

- 要件、公開挙動、対象パス、完了条件のいずれかを一意に決められない
- 新しいAPI、認可境界、migration、設定、依存関係、CI、スキル、Git管理ファイルを変更する
- 新しいテストシナリオまたは既存テストの意味変更が必要になる
- 許可パスに未コミット変更がある

対象ファイルがまだ存在しないこと、または許可パスが複数あることだけを理由に停止してはならない。追加依頼では未実装が前提である。単一の公開挙動について同じ既存パターンから各変更を一意に決められる限り、複数の本体コードと`schema.prisma`を一つのerrandで扱う。Prisma modelのフィールド、型、主キー、relationを依頼または同型実装から一意に決められない場合は停止する。migration fileの作成と`prisma migrate`・`prisma db push`・`prisma db execute`は常に禁止する。

## 実行手順

1. ユーザーの依頼だけから、変更後の公開挙動、完了条件、候補となる変更パスを短く固定する。依頼に含まれる識別子、パス、番号、固有名詞を完全な文字列のまま保持し、省略、翻訳、一般化してはならない。上の停止条件に当たるなら停止する。
2. 既存の実装挙動を調査する必要がある場合は、DeepSeekのsurvey modeを同期実行し、上位モデルによる同範囲の重複調査を最初から行わない。

   ~~~bash
   bash [skills_root]/deepseek/delegate.sh survey \
     --hard-timeout-minutes <総待機分> \
     --idle-timeout-seconds <無通信秒> \
     --poll-seconds <確認間隔秒> \
     <task-id> <調査指示>
   ~~~

   調査指示の先頭に保持した完全な識別子を列挙し、完全一致、構成要素の一致、最寄りの同型実装の順に探索させる。同型実装は最も近い1件だけを選び、本体コードの正確なパス、置換要素、既存の検証コマンドが揃った時点で終了させる。設定、DB、schema、migration、テストの網羅監査、リポジトリ全体の反証探索、未調査範囲の列挙を依頼してはならない。これらは選んだ同型実装が直接参照する場合だけ報告させる。

   survey commandが返る前に`show`を呼ばず、同じ調査を別task-idで並行起動しない。会話中断後に状態を確認する場合だけ`show`を一度使い、`running`または`orphaned-running`なら再試行しない。接続失敗、timeout、最終応答欠落では新しいtask-idで1回だけ再試行する。2回続けて失敗したら上位モデル相当のAgent / subagentを読み取り専用で優先し、使えなければ上位モデル自身が調査する。明示的な認証失敗では再試行せず、直ちに同じ代替経路へ切り替える。

   実行器が標準出力へ返すreportから、最寄りの同型実装と不足情報を受け取る。通常はreportを採用して同じ範囲を重複調査しない。surveyの隔離worktreeはmetadataの`source_snapshot: HEAD`だけを調査し、metadataの`source_worktree_status`に列挙されたメイン作業ツリーのdirty差分を反映しない。reportが不足とした依存先とdirty pathが関係する場合は、上位モデルがその差分を読み取り専用で確認する。dirty pathを許可対象へ追加したり変更したりしてはならない。DeepSeekと代替subagentは探索と根拠収集だけを担当し、errand適用可否と実装指示の確定は上位モデルが行う。
3. 依頼とsurvey結果だけから、変更内容、守る既存パターン、完了条件を含む短い実装指示を作る。対象はcleanな追跡済み本体コードと`schema.prisma`、または既存の親ディレクトリ内でまだ存在せず、同型実装から配置・名前・内容を一意に決められる新規本体ファイルだけにする。テスト、Markdown、設定、migration、lockfile、環境変数、Git管理ファイルを許可対象にしてはならない。
4. 固定実行器へ実装を委任する。

   ~~~bash
   bash [skills_root]/deepseek/delegate.sh errand \
     --hard-timeout-minutes <総待機分> \
     --idle-timeout-seconds <無通信秒> \
     --poll-seconds <確認間隔秒> \
     <task-id> <短い実装指示> -- <許可する本体コードまたはschema.prisma>
   ~~~

   surveyとerrandの各実行前に、調査範囲または実装範囲と難易度から3つの時間値を選び、値と理由を明示する。DeepSeekにテスト、設定、migration、Git、設計資産を変更させない。task-idはlowercase kebab-caseとし、同じtask-idを再利用しない。応答失敗時は新しいtask-idと選び直した3値で1回だけ再委任する。2回続けて失敗した場合、または明示的な認証失敗があった場合は、上位モデル相当のAgent / subagentを許可パス限定で優先し、使えなければ上位モデル自身が実装する。予算超過、ZDR非対応、依存command欠落は応答失敗に数えず停止する。
5. command完了後に`bash [skills_root]/deepseek/delegate.sh show <task-id>`でresult metadata、report、candidate.patchを取得し、候補パッチを確認する。`status != 0`または`timed_out: true`ならcandidate.patchは診断専用として拒否し、応答失敗として上の再試行規則を適用する。候補が正常に返った後は、許可パス外の変更、曖昧さの握り潰し、ハードコード、既存契約との不一致を上位モデルがレビューし、必要な修正を直接行う。
6. 採用したDeepSeek候補を反映して初回実装とする。その後は上位モデルが、対象の既存テスト、Prisma format / validate / generate、型検査、lint、回帰確認から関係するものだけを実行し、失敗やレビュー指摘を本体コードへ直接修正する。migration commandを実行してはならない。`polish`や`unwind`など別のworkflow skillを自動追加しない。必要なテストシナリオが増えた場合は変更を進めず停止する。

ユーザーが停止後に設定やmigration fileなどerrand禁止対象の変更を明示した場合は、`errand`を終了して通常実装へ移ることを一文で宣言する。明示された範囲だけを通常実装として扱い、errandを続行したことにして禁止対象を委任してはならない。

## 完了報告

依頼、DeepSeek の survey / errand task-id、許可パス、候補パッチの採否、実行した検証、コミットを簡潔に報告して停止する。
