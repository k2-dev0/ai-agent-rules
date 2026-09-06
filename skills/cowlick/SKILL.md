---
name: cowlick
description: "meeting から呼ばれ、確定要件から `.[agent_name]/prompt/` の設計書を直接作成・更新する"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
user-invocable: false
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/load-required-contract.sh cowlick-design
---

開始時に[設計・実装の判断基準](../IMPLEMENTATION_RULES.md)を読み、対象に該当する規約と既存例だけを確認する。

## 目的

確定要件から `.[agent_name]/prompt/` の設計書を直接作成・更新する。要件監査、質問、単純化はmeetingが統括する。設計書の配置を承認のために二重化しない。

## 実行

開始時に[設計書形式](DESIGN_FORMAT.md)を全文読む。hookの有効化・信頼状態に依存せず、形式と設計根拠を入力へ含める。

1. 同じ要件revisionの`preflight_ready`が現在の会話にあることを確認する。欠落、対象変更、重大な未回答があれば`preflight_required`を返す。
2. **明示要件**、**禁止・制約**、**受入済みtrade-off**、**既存制約**だけを固定条件にし、**設計選択**を要件へ昇格させない。
3. `.[agent_name]/prompt/` の既存設計書は現在のrevisionだと確認できるときだけEditする。別要件、所有者不明、revision不明なら触れず`design_conflict`を返す。
4. 既存経路と新設予定の実行・永続化・運用境界を一列にし、preflightの基準案と根拠を共通判断基準へ照合して設計する。
5. `.prompt.md`と`branch-<機能名>-prompt.md`を `.[agent_name]/prompt/` へ直接作成・更新する。初回はWrite、改訂はEditを使う。

疑似コードの言語、必要な実装情報、圧縮可能な範囲は設計書形式に従い、実装時の再設計が不要なChangesを作る。

### コードベース調査

[agent_name]が各設計書を1枚ずつコードベースと直接照合する。下位モデル、subagent、外部workerへ調査を委任しない。次を確認済み根拠の`path:line`、不明点、設計リスクとともに確認する。

- 設計書ごと削除できる既存経路
- 新しいendpointやruntime resourceを使わない入口
- 既存のdeployment、scheduling、failure recovery pattern
- 共通判断基準に沿った新設要素の必要性と既存例
- 新設要素が生んだ失敗モードと緩和策をまとめて消せる反証

参照先または必須根拠が得られない場合は、理由と未調査範囲を含む`research_blocked`をmeetingへ返す。要件revisionと異なる判断が必要なら、選択肢、挙動差、推奨を含む`consultation_required`をmeetingへ返す。

調査後に全設計書を横断し、共通判断基準を満たすことと、Changesが設計書形式の実装情報を保持していることを確認する。満たせばファイル名と内容で識別できるdesign revisionと`design_ready`を返して停止し、ponytailへ自動で進まない。
