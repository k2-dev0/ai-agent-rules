---
name: context-update
description: context-dictionary API に登録済みの知見を更新・follow-up を管理する。
allowed-tools: Bash
disable-model-invocation: true
---

## 実行

引数があれば対象と操作を抽出し、なければ「どの知見をどう更新しますか？」と一度だけ尋ねる。`../context-api/API.md`を全文読んでから操作する。

1. ID指定時は単件取得する。ID不明なら語句、type、tagから検索し、候補が1件なら採用、複数なら選択を求める。
2. 現在のInsightまたはfollow-up一覧を取得する。
3. 変更前後の差分を提示し、更新承認を得る。
4. Insightの部分更新、follow-up追加、`resolved`の変更から該当endpointを使う。

`tags`と`relations`は全置換なので、差分変更にはadd/remove fieldを使う。全置換が必要なら既存値を取得して意図した最終配列を示す。対象特定と更新承認以外の質問は増やさない。serverへ到達できなければ通知して終了する。
