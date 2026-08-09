---
name: context-save
description: セッションで得た知見を context-dictionary API に登録する。
allowed-tools: Bash
disable-model-invocation: true
---

## 実行

引数があれば記録したい概要として使い、なければ何を記録するか一度だけ尋ねる。会話、編集、実行結果から知見を自律的に組み立て、複数の独立した知見は別Insightにする。

各Insightは`discovery`、`decision`、`solution`、`issue`、`caveat`からtypeを選び、具体的なcontent、必要なdetail・tags・followUps、現在のrepo・branchを付ける。`decision`にはrationaleを必須とする。

送信前にtype、content、主要tagsを一覧で提示し、一度だけ承認を得る。承認後に`../context-api/API.md`を全文読み、1件は単件、複数件はbulk endpointへ送る。質問は概要と送信承認に必要な最小限に留める。

曖昧な「問題を解決した」ではなく、将来の利用者が条件・原因・解決を識別できる内容にする。serverへ到達できなければ通知して終了する。
