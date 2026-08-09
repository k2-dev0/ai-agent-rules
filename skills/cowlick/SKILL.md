---
name: cowlick
description: "meeting から draft または apply mode で呼ばれ、確定要件から未承認の設計ドラフトを作るか、ponytail 後に最終承認された同一 revision を @.[agent_name]/prompt/ へ正式反映する"
allowed-tools: Read, Write, Edit, Bash, Agent
user-invocable: false
---

## 目的

確定要件から未承認ドラフトを作る責務と、最終承認済みドラフトを正式反映する責務を持つ。要件監査、質問、単純化、最終承認はmeetingが統括する。

## mode

meetingから渡された先頭引数だけを使う。

- `draft`: 同じ要件revisionの`preflight_ready`からドラフトを作る
- `apply`: 同じdraft revisionの`ponytail_ready`とユーザー承認を確認して正式反映する
- それ以外: 変更せず`invalid_mode`を返す

## draft

1. 同じ要件revisionの`preflight_ready`が現在の会話にあることを確認する。欠落、対象変更、重大な未回答があれば`preflight_required`を返す。
2. **明示要件**、**禁止・制約**、**受入済みtrade-off**、**既存制約**だけを固定条件にし、**設計選択**を要件へ昇格させない。
3. `draft-prompt/`が既にある場合、現在のrevisionだと確認できるときだけEditする。別要件、所有者不明、revision不明なら触れず`draft_conflict`を返す。
4. 既存経路と新設予定の実行・永続化・運用境界を一列にし、境界を新設しない基準案を優先する。新しいpublic endpoint、queue、scheduler、worker、serverless function、外部接続、global/shared変更は、基準案で満たせない明示要件または既存制約がある場合だけ加える。
5. `DESIGN_FORMAT.md`を全文読み、未承認の`.prompt.md`と`branch-<機能名>-prompt.md`だけをプロジェクトルートの`draft-prompt/`へ作る。正式領域へは書かない。

疑似コードは予約語・構文を英語、新しく設計する識別子と処理内容を日本語で書く。圧縮は重複説明と同一の外枠に限定する。非自明な関数、validation、DB / API処理では、signature、guard順、条件・計算式、取得・sort条件、正常・errorの返却、dataの権威、副作用の順序がChangesにないまま`draft_ready`を返さない。

ディレクトリがなければ、次をプロジェクトルートから単独実行する。workspace sandbox内の通常作成なので承認を要求せず、他commandと連結しない。

```bash
mkdir -p draft-prompt
```

`draft-prompt/`へメモを置かず、コミットしない。初回はWrite、改訂はEditを使う。

### コードベース調査

`../deepseek/DELEGATION.md`を全文読み、各設計書をDeepSeekの`research`へ1枚ずつ渡す。コード、テスト、ドラフトは変更させず、次を`file:line`の根拠、不明点、設計リスクとともに探させる。

- 設計書ごと削除できる既存経路
- 新しいendpointやruntime resourceを使わない入口
- 既存のdeployment、scheduling、failure recovery pattern
- 新設要素が生んだ失敗モードと緩和策をまとめて消せる反証

共通契約の代替調査まで使えない場合は、理由と未調査範囲を含む`research_blocked`をmeetingへ返す。重要な根拠は[agent_name]が実ファイルで再確認する。DeepSeekと代替subagentは探索だけを担当し、設計判断とドラフト更新は[agent_name]が行う。要件revisionと異なる判断が必要なら、選択肢、挙動差、推奨を含む`consultation_required`をmeetingへ返す。

調査後に全設計書を横断し、各新設境界とglobal/shared変更が明示要件または既存制約へ直接対応し、基準案では満たせないことを確認する。設計選択同士にしか依存しない要素を残さない。Changesが実装時の再設計を必要とせず、重要な分岐・式・順序・契約を保持していることも確認する。満たせばファイル名と内容で識別できるdraft revisionと`draft_ready`を返して停止し、ponytailやapplyへ自動で進まない。

## apply

次をすべて満たす場合だけ固定スクリプトを実行する。

1. ponytailが現在のdraft revisionへ`ponytail_ready`を返した
2. ユーザーが同じrevisionを最終承認した
3. 承認後にファイル名と内容が変わっていない

満たさなければ`ponytail_required`または`approval_required`を返す。古い承認を流用しない。

```bash
bash [skills_root]/cowlick/apply-prompt.sh
```

この引数なしの相対パスcommandをプロジェクトルートから単独実行する。絶対パス、`./`、別shell、複合command、redirectへ変えない。固定スクリプトは次を原子的に行う。

- `draft-prompt/`がindexと対応する設計書だけを持つか検証する
- `.[agent_name]/prompt/`へ反映し、今回のindexにない旧設計書だけを除く
- 成功時だけ検証済みの移動元を畳み、想定外ファイルは残して警告する

Claude Codeではsandbox除外と事前allow、Codexではdistributed permission profileと`.codex/rules/default.rules`がこの固定経路だけを許可する。失敗時は別commandで迂回せず、相対パス、project trust、配置済み設定を確認する。
