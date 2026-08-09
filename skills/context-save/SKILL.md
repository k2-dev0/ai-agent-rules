---
name: context-save
description: セッションで得た知見を context-dictionary API に登録する。
allowed-tools: Bash
disable-model-invocation: true
---

## 実行

引数があれば記録対象として使い、なければ何を記録するか一度だけ尋ねる。次の単位でInsightを作る。

- 別々に再利用できる結論は分ける
- 同じ問題の条件・原因・修正・検証は一つの`solution`へまとめる
- 同じ結論の言い換えや、作業ログだけの情報は保存しない

| type | 使う条件 |
|---|---|
| `discovery` | 確認済みの仕様・構造・事実 |
| `decision` | 選択した方針。`rationale`を必須にする |
| `solution` | 問題の条件・原因・解決・検証が揃ったもの |
| `issue` | 未解決で追跡が必要な問題 |
| `caveat` | 誤用しやすい制約・例外・副作用 |

`content`は条件と結論が分かる一文、`detail`は根拠・手順・検証、tagsは検索に使う安定した名詞を1〜5個、followUpsは未完了の具体的行動だけにする。git repository内なら現在のrepo・branchを付ける。

送信前に件数と各Insightの`type`、`content`、tags、decisionのrationaleを提示し、一度だけ承認を得る。承認後に`../context-api/API.md`を全文読み、1件は単件、複数件はbulk endpointへ送る。serverへ到達できなければ成功扱いせず通知する。
