---
name: tdd
description: ユーザーが引数なしの`$tdd`を明示し、`@.[agent_name]/prompt/.prompt.md`の先頭未完了設計書1枚を上位モデルが調査・テストし、下位implementerに初回実装だけを委任し、上位モデルがレビュー・修正・polishを完了するときに使う。
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent, Skill(polish)
disable-model-invocation: true
---

## 目的

`.prompt.md`の先頭未完了設計書1枚を`direct survey → scenario → red → lower-model implementer → review-green → polish`で完了する。調査、シナリオ、テスト、Red、初回実装、Greenは[シナリオ駆動の共通実装フロー](SCENARIO_FLOW.md)を全文読んで正本とし、このスキルでは設計書選択、上位モデルの調査、polish、index更新だけを追加する。

## 対象の選択

`$tdd`は引数を受け取らない。`@.[agent_name]/prompt/.prompt.md`の先頭の`- [ ] branch-<機能名>-prompt.md`だけを対象にし、他の設計書は読まない。引数がある、indexがない、未完了項目がない、または参照先がない場合は変更せず停止する。

未完了項目がなければ全設計書が完了済みと報告する。対象設計書は1 branch・1 PRの単位として扱い、次の設計書へ自動で進まない。

## 権限境界

| 対象 | [agent_name] | lower-model implementer |
|---|---|---|
| 要件判断・リポジトリ調査・テストシナリオ設計 | 可 | 禁止 |
| テスト資産の変更 | ユーザーが選択したtest_scenarios内だけ可 | 禁止 |
| 設計資産の変更 | meetingで作成・更新したprompt正本だけ可 | 禁止 |
| 本体コード、schema、既存test、同型実装の調査 | 可 | 要求に直接必要な範囲で可 |
| production codeと`schema.prisma`の初回実装 | implementerが利用不能またはcleanな再実行も失敗した場合だけ可 | 可 |
| 初回実装後の本体コード修正 | 可 | 禁止 |
| テスト実行・レビュー・Git | 可 | 禁止 |

テスト資産にはtest/spec、fixture、factory、mock、stub、fake、snapshot、golden file、テスト設定、CI上のテスト実行設定を含める。implementerへはこれらと、一般設定、migration、依存関係、lockfile、agent設定、設計資産、Git管理ファイルを変更させない。

## 上位モデルの直接調査

設計書を要求根拠とし、[agent_name]が次を直接調査する。下位モデル、surveyor subagent、外部workerへ調査を委任しない。

- 現在の対象挙動・型・保存先
- 最寄りの同型実装1件と置換する識別子・値
- schema、設定、test、routeなど実装判断に直接必要な境界
- 対象へ直接使う既存検証command

すべてを毎回追わず、要求判断を直接支える最小範囲から読む。確認済み事実、根拠の`path:line`、想定変更先、直接関係するtest・検証command、未確認事項を実装briefに保持する。必須情報が不足する場合は[agent_name]が追加調査する。

## 実行フロー

### 1. 対象と既存状態を確認する

indexから対象設計書を選び、対象設計書1枚を読む。ユーザー由来の未コミット変更があっても読み取り調査は行えるが、共有worktreeへimplementerを起動してはならない。変更の所有者を推測せず、Red用testをコミットした後も残るdirty fileがあれば実装前に停止する。

### 2. 上位モデルが調査する

共通フローのStep 0に従い、[agent_name]がコードベースを直接読み、必要な事実と検証commandを確定する。

### 3. 共通のシナリオ駆動実装フローを完了する

共通フローのStep 1〜8を順に実行する。ユーザーがテスト作成済みと明示した場合はStep 1と2を省略できるが、既存テストの契約確認とRedは残す。

追跡対象のRed用testをリポジトリのGit規約どおりコミットし、worktreeがcleanであることを確認する。native implementer起動直前に次を1回実行する。

```bash
bash [skills_root]/polish/capture-scope.sh <機能名> --auto
```

これはpolish用の基準commitだけを記録し、subagentの読み取り・書き込みを制限しない。implementerには設計書の全要件、[agent_name]が確認した事実、test_scenarios、Red、想定変更先、変更禁止カテゴリを自然文で渡す。想定変更先は探索の起点であり、要件内の追加production fileを拒否する根拠にしない。

### 4. polishと完了処理を行う

設計書の完了条件、共通フローのGreenまたはtest除外、レビュー、追跡対象のコミットを確認してから、次を実行する。

```bash
bash [skills_root]/polish/capture-scope.sh list-changed <機能名>
```

この出力にある実変更pathだけをまとめて`polish`へ渡し、ファイルごとには呼ばない。`polish`はformatter・lint・`unwind`を実変更pathだけへ適用し、最後にbaselineからの実変更pathと入力の完全一致を検査する。formatterの自動修正は必要範囲だけ再確認し、上位モデルがコードを判断して修正した場合は全品質ゲートを先頭から再実行する。

実装差分、検証結果、`unrelated`・`uncertain`・`not run`を先にユーザーへ報告し、完了マークを付けるか明示的に確認する。ユーザーが付けると回答した場合だけ次を単独実行する。

```bash
bash [skills_root]/tdd/mark-prompt-done.sh <機能名>
```

## 例外停止

- ユーザー由来のdirty fileが残り、共有worktreeへwriterを安全に起動できない
- DB、依存関係、公開APIなど承認範囲外の変更が必要になる
- 確認した事実と要求根拠が矛盾し、新しい設計判断が必要になる
- implementerの専用agent定義をpreflightできない

## 完了報告

- 対象設計書と選択済みtest_scenarios
- RedとGreen、またはtest除外
- [agent_name]が調査した範囲と確認した事実
- implementerの結果、実差分の採否、上位修正
- polish結果とscope帰属
- リポジトリ規約に従ったコミット
- indexの残件数。完了マークはユーザーが明示した場合だけ更新
