## 入力

開始時に[判断基準](../IMPLEMENTATION_RULES.md)・該当規約と[設計書形式](DESIGN_FORMAT.md)を全文読む。

| 条件 | 返却 |
|---|---|
| 同じ要件revisionの`preflight_ready`なし、対象変更、重大な未回答 | `preflight_required` |
| 既存設計書が別要件・所有者不明・revision不明 | 変更せず`design_conflict` |

## 手順

1. 明示要件・禁止制約・受入済みtrade-off・既存制約を固定し、設計選択は変更可能として扱う。
2. 既存・新設予定の実行・永続化・運用境界を整理し、preflightの基準案とコード根拠を共通判断基準へ照合する。
3. [agent_name]が各設計書をコードベースと照合する。サブエージェントへ調査を委任しない。
4. 設計書形式に従い、`.[agent_name]/prompt/`の`.prompt.md`と`branch-<機能名>-prompt.md`を直接更新する。初回はWrite、改訂はEdit。
5. 設計書形式の必須sectionを埋め、設計書形式の実装情報を保持する。設計全体の監査は後段のponytailへ渡す。

| 調査・レビュー | 確認 |
|---|---|
| 既存経路 | 設計書ごと削除できる再利用先 |
| 入口・運用 | endpoint・runtime resourceを増やさない案、既存deployment・scheduling・failure recovery |
| 新設要素 | 必要性、配置・命名・exportの既存例、consumer |
| 失敗対策 | 新設要素と緩和策を対で削除できるか |

結果には`path:line`、不明点、設計リスクを付ける。

## 返却

| status | 条件 |
|---|---|
| `design_ready` | 設計書一式の作成・更新完了。file名と内容で識別できるdesign revisionを返す |
| `research_blocked` | 参照先・必須根拠が不足。未調査範囲を返す |
| `consultation_required` | 要件revisionと異なる判断が必要。選択肢・挙動差・推奨を返す |

呼出元へ返して停止し、ponytailへ直接進まない。
