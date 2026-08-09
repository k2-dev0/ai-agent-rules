# context-dictionary API

context系スキルはHTTP request前にこの文書を全文読む。base URLは`http://localhost:3210`、JSON requestは`Content-Type: application/json`を使う。serverへ到達できなければユーザーへ通知し、推測で成功扱いしない。

## Insight

| field | 型 | 契約 |
|---|---|---|
| `type` | string | `discovery`、`decision`、`solution`、`issue`、`caveat` |
| `content` | string | 必須の短い概要 |
| `detail` | string | 任意の手順・背景・code |
| `rationale` | string | `decision`では必須 |
| `agent` | string | 必須、最大50文字 |
| `repo`、`branch` | string | 任意、最大200文字 |
| `sessionId` | string | 任意、最大100文字 |
| `tags`、`followUps` | string[] | 任意 |
| `relations` | object[] | 任意の`{targetId, type}` |

## endpoint

| 操作 | method / path |
|---|---|
| 単件登録 | `POST /api/insights` |
| 一括登録 | `POST /api/insights/bulk` |
| 一覧・絞り込み | `GET /api/insights` |
| 単件取得 | `GET /api/insights/:id` |
| 全文検索 | `GET /api/search?q=<query>` |
| タグ一覧 | `GET /api/tags` |
| 知見の部分更新 | `PATCH /api/insights/:id` |
| follow-up追加 | `POST /api/insights/:id/follow-ups`、bodyは`{"content":"..."}` |
| follow-up解決状態 | `PATCH /api/follow-ups/:id`、bodyは`{"resolved":true|false}` |

一覧は`agent`、`type`、`tag`、`repo`、ISO 8601の`from` / `to`、content部分一致の`q`、既定20件の`limit`、既定0の`offset`を受ける。全文検索は`type`と`agent`も受ける。

InsightのPATCHは全field任意。`tags`と`relations`は全置換であり、既存値を保つ追加・削除には`addTags`、`removeTags`、`addRelations`、`removeRelations`を使う。全置換fieldと対応する差分fieldを同時送信しない。更新前にGETし、変更しない値を壊さないことを確認する。
