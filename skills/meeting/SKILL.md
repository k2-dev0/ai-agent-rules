---
name: meeting
description: "ユーザーが `$meeting` を明示して呼ぶ設計フロー。preflight → cowlick → ponytailを実行し、設計書を作成・更新する。通常の自然言語による軽微な修正・追加依頼では起動しない。"
allowed-tools:
  - Skill(preflight)
  - Read
  - Grep
  - Glob
  - Write
  - Edit
  - Bash
  - Agent
  - AskUserQuestion
disable-model-invocation: true
---

## 起動

`$meeting` の明示呼び出しでだけ起動する。引数、なければ直前の会話から対象を決め、不明な場合だけ質問する。

preflight・cowlickの調査はメインが行い、ponytailの監査は履歴を継承しない専用子へ渡す。内部工程の選択・再実行は自分で行い、ユーザーにしか決められない事項を一件ずつ質問する。回答済みの事項は聞き直さない。

## 手順

`preflight → cowlick → ponytail` の順で実行する。要件・design・監査のrevisionは会話内で管理し、変更後に古い結果を流用しない。preflightはskillとして呼び、cowlick・ponytailはその工程へ進む直前に下表の手順を読み、変更範囲と承認条件に従う。

| 工程 | 進め方・戻り先 |
|---|---|
| preflight | 要件由来、既存の実行方式、境界を新設しない基準案を確認する。未決定事項を影響順に一件ずつ質問し、回答後に再調査する。`preflight_ready`まで進まない |
| cowlick | [手順](../cowlick/PROCEDURE.md)に従い、preflightの要件・制約・受入済み副作用・未確認事項・コード根拠を渡し、`.[agent_name]/prompt/`を直接更新する。前提変更はpreflightへ、設計判断は質問後に再実行。`design_ready`まで進まない |
| ponytail | [手順](../ponytail/PROCEDURE.md)に従い、元の要件・禁止制約・受入済みtrade-off、要件・設計revision、現在の`.prompt.md`と参照先設計書を渡す。起動・指摘対応・再レビューはponytailに従う |
| 監査結果の確認 | ユーザー判断が必要なら質問し、目的・範囲の変更はpreflightへ、設計・完了条件の変更や新設要素の追加はcowlickへ戻す。`blocked`は理由を報告して停止する |

機能・公開契約・data・security・互換性を変える候補はユーザー判断へ戻す。

## 成功・失敗

ponytailが検証した結果の要件・設計revision、対象path・hash・HEADを現在の対象と照合する。不一致なら該当工程へ戻す。一致した`ponytail_ready`だけで完了し、他statusは上表の戻り先へ進む。監査成果物の詳細検証はponytailが担当する。

skill・設計書・必須根拠が欠ける場合は、該当工程で停止する。未確認事項はユーザーが明示的に受け入れた場合だけ持ち越す。同じ会話内の再調査を、履歴を隔離した別agentの監査とは呼ばない。

## 報告

設計書、確定範囲、重要なユーザー判断、受入済み副作用、削除・再利用した項目、残る境界・上限・測定可能な再検討条件、持ち越した未確認事項を簡潔に報告する。

最終報告で新たな承認待ちは設けない。設計書を更新したら、影響する工程へ戻る。
