---
name: dictionary
description: context-dictionary MCPで過去の知見を検索・取得し、承認後に保存・更新する。
---

## 検索

過去の仕様・判断・解決策が関係する場合は`search`。現在のrepositoryと、意図から一意に決まる場合だけtypeを渡す。元の語句から固有名詞2〜4個を選べる場合だけ`fallbackQuery`を使う。

検索段階、候補ID・type・更新日・content、存在するrationale・未解決follow-up・relationを示す。詳細は`get`で取得する。類似だけで更新IDを推測せず、候補が複数なら選択を求める。

## 保存・更新

- 再利用できる結論ごとに分け、同じ問題の条件・原因・修正・検証は一つの`solution`にする。重複・作業ログだけの情報は保存しない。
- contentは条件と結論の一文、detailは根拠・手順・検証、tagsは名詞1〜5個。decisionにはrationale、repo内の知見にはrepo・branchを付ける。
- `upsert`／`follow_up`前に件数・ID・type・content・tags・rationale・変更差分を提示する。承認なしに書き込まない。
- createはIDなし。updateは`get`の明示IDとversionを`expectedVersion`へ渡し、未指定fieldは保持する。
- 競合時は最新値と差分を再取得し、再承認を得る。
- follow-upはupsertと分け、add・resolve・reopenを指定する。
