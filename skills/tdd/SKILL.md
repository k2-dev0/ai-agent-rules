---
name: tdd
description: ユーザーが引数なしの`$tdd`を明示し、`@.[agent_name]/prompt/.prompt.md`の先頭未完了設計書1枚を上位モデルが調査・テストし、下位implementerに初回実装と大きい修正の再実装を委任し、上位モデルがレビュー・polishを完了するときに使う。
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent, Skill(polish)
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: Agent
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/require-implementer.sh workflow
---

## 目的

`.prompt.md`の先頭未完了設計書1枚を`direct survey → scenario → red → lower-model implementer → review-reimplementation → green-final-review → polish`で完了する。調査、シナリオ、テスト、Red、初回実装、再実装、Green、最終レビューは[シナリオ駆動の共通実装フロー](../SCENARIO_FLOW.md)を全文読んで正本とし、このスキルでは設計書選択、polish、index更新だけを追加する。

## 対象の選択

`$tdd`は引数を受け取らない。`@.[agent_name]/prompt/.prompt.md`の先頭の`- [ ] branch-<機能名>-prompt.md`だけを対象にし、他の設計書は読まない。引数がある、indexがない、未完了項目がない、または参照先がない場合は変更せず停止する。

未完了項目がなければ全設計書が完了済みと報告する。対象設計書は1 branch・1 PRの単位として扱い、次の設計書へ自動で進まない。

## 実行フロー

### 1. 対象と既存状態を確認する

indexから対象設計書を選び、対象設計書1枚を読む。ユーザー由来の未コミット変更があっても読み取り調査は行えるが、共有worktreeへimplementerを起動してはならない。変更の所有者を推測せず、Red用testをコミットした後も残るdirty fileがあれば実装前に停止する。

### 2. 共通のシナリオ駆動実装フローを完了する

対象設計書を要求根拠、機能名をscope名として、共通フローのStep 0〜8を実行する。調査、テスト選択と例外、Red、baseline取得、implementerへのbrief、レビューとGreenは共通フローへ従う。

### 3. polishと完了処理を行う

設計書の完了条件、共通フローのGreenまたはtest除外、レビュー、追跡対象のコミットを確認してから、次を実行する。

```bash
bash [skills_root]/polish/capture-scope.sh list-changed <機能名>
```

この出力にある実変更pathだけをまとめて`polish`へ渡し、ファイルごとには呼ばない。品質検査、修正時の再実行、path完全性の確認はpolishのフローに従う。

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
- implementerの結果、実差分の採否、大小判定、修正主体、最終レビュー
- polish結果とscope帰属
- リポジトリ規約に従ったコミット
- indexの残件数。完了マークはユーザーが明示した場合だけ更新
