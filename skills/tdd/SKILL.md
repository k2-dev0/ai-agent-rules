---
name: tdd
description: "引数なしの$tddで、先頭未完了設計書1枚を実装・レビュー・polishする。"
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion, Agent, Skill(polish)
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: Agent
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/require-implementer.sh workflow
---

## 対象

引数なしで`@.[agent_name]/prompt/.prompt.md`の先頭`- [ ] branch-<機能名>-prompt.md`だけを読む。他の設計書や次の項目へ進まない。1枚を1 branch・1 PRとして扱う。

引数あり、index・参照先なしは変更せず停止する。未完了項目なしなら完了済みと報告する。

## 手順

1. 対象設計書を読み、[共通実装フロー](../SCENARIO_FLOW.md)を全文読む。
2. 設計書を要求根拠、機能名をscope名として共通フローのStep 0〜8を実行する。ユーザー由来のdirty fileがあっても調査はできるが、Red用testのcommit後も残る場合はimplementerを起動しない。
3. 設計書の完了条件、Greenまたはtest除外、レビュー、追跡対象のcommitを確認し、次を実行する。

```bash
bash [skills_root]/polish/capture-scope.sh list-changed <機能名>
```

この出力にある実変更pathだけをまとめて`polish`へ渡し、ファイルごとには呼ばない。

4. 実差分・検証結果・`unrelated`・`uncertain`・`not run`を報告し、完了マークを付けるか明示的に確認する。ユーザーが付けると回答した場合だけ単独実行する。

```bash
bash [skills_root]/tdd/mark-prompt-done.sh <機能名>
```

## 停止・報告

dirty file、承認範囲外のDB・依存・公開API変更、新しい設計判断、implementerの専用定義を確認できない場合は停止する。

対象設計書、選択済みシナリオ、Red・Green／test除外、調査結果、実差分の採否・大小判定・修正主体・最終レビュー、polish・検証分類、commit、index残件数を簡潔に報告する。
