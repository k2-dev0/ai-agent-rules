---
name: cowlick
description: "meeting から呼ばれ、確定要件から `.[agent_name]/prompt/` の設計書を直接作成・更新する"
allowed-tools: Read, Write, Edit, Bash, Agent
user-invocable: false
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/load-required-contract.sh cowlick-design
---

## 目的

確定要件から `.[agent_name]/prompt/` の設計書を直接作成・更新する。要件監査、質問、単純化はmeetingが統括する。設計書の配置を承認のために二重化しない。

## 実行

1. 同じ要件revisionの`preflight_ready`が現在の会話にあることを確認する。欠落、対象変更、重大な未回答があれば`preflight_required`を返す。
2. **明示要件**、**禁止・制約**、**受入済みtrade-off**、**既存制約**だけを固定条件にし、**設計選択**を要件へ昇格させない。
3. `.[agent_name]/prompt/` の既存設計書は現在のrevisionだと確認できるときだけEditする。別要件、所有者不明、revision不明なら触れず`design_conflict`を返す。
4. 既存経路と新設予定の実行・永続化・運用境界を一列にし、境界を新設しない基準案を優先する。新しいpublic endpoint、queue、scheduler、worker、serverless function、外部接続、global/shared変更は、基準案で満たせない明示要件または既存制約がある場合だけ加える。
5. `.prompt.md`と`branch-<機能名>-prompt.md`を `.[agent_name]/prompt/` へ直接作成・更新する。初回はWrite、改訂はEditを使う。

疑似コードは予約語・構文を英語、新しく設計する識別子と処理内容を日本語で書く。圧縮は重複説明と同一の外枠に限定する。非自明な関数、validation、DB / API処理では、signature、guard順、条件・計算式、取得・sort条件、正常・errorの返却、dataの権威、副作用の順序がChangesにないまま`design_ready`を返さない。

### コードベース調査

各設計書をworkerの`research`へ1枚ずつ渡す。コード、テスト、設計書は変更させず、次を共通契約のclaim-evidence、不明点、設計リスクとともに探させる。
`research`は必ず`bash [skills_root]/worker/delegate.sh research`で実行する。

- 設計書ごと削除できる既存経路
- 新しいendpointやruntime resourceを使わない入口
- 既存のdeployment、scheduling、failure recovery pattern
- 新設要素が生んだ失敗モードと緩和策をまとめて消せる反証

共通契約の代替調査まで使えない場合は、理由と未調査範囲を含む`research_blocked`をmeetingへ返す。検証済みevidenceがclaimを直接支える場合は同じ箇所を再読しない。要件revisionと異なる判断が必要なら、選択肢、挙動差、推奨を含む`consultation_required`をmeetingへ返す。

調査後に全設計書を横断し、各新設境界とglobal/shared変更が明示要件または既存制約へ直接対応し、基準案では満たせないことを確認する。設計選択同士にしか依存しない要素を残さない。Changesが実装時の再設計を必要とせず、重要な分岐・式・順序・契約を保持していることも確認する。満たせばファイル名と内容で識別できるdesign revisionと`design_ready`を返して停止し、ponytailへ自動で進まない。
