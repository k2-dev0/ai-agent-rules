---
name: context-search
description: context-dictionary API から過去の知見を検索・取得し、現在の作業に活用する。
allowed-tools: Bash
disable-model-invocation: true
---

## 実行

引数があれば検索意図として使い、なければ何を探すか一度だけ尋ねる。検索条件の確認は求めず、`../context-api/API.md`を全文読んで自律的に検索する。

- 語句を`q`または全文検索へ渡す
- 対応策=`solution`、判断理由=`decision`、仕様=`discovery`、課題=`issue`、注意=`caveat`をtype候補にする
- 必要ならtag、repo、agent、期間を加え、複数検索を組み合わせる
- 0件なら語句を変え、typeなどの絞り込みを外して再検索する

結果は関連度順にtype、日付、contentを整理し、decisionのrationale、未解決followUps、relationsも示す。生JSONをそのまま返さない。serverへ到達できなければ通知して終了する。
