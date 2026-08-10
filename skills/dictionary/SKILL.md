---
name: dictionary
description: context-dictionary MCPで過去のInsightを検索・取得し、再利用可能な知見の保存、明示ID更新、follow-up管理を行う。過去の判断や解決策を探すとき、または作業で得た知見を記録・更新するときに使う。
---

# Dictionary

## 検索する

過去の仕様、判断、解決策が現在の作業に関係しそうなら`search`を使う。現在のrepositoryと、意図から一意に決まる場合だけtypeを渡す。元の語句から2〜4個の固有名詞を安全に選べる場合だけ`fallbackQuery`を渡し、検索段階、候補ID、type、更新日、contentと、存在するrationale・未解決follow-up・relationを示す。

ID指定の詳細確認には`get`を使う。更新対象のIDをcontent、title、tagの類似だけで推測しない。IDが不明で候補が複数なら、候補を示して利用者に選ばせる。

## Insightをまとめる

- 別々に再利用できる結論は分ける
- 同じ問題の条件・原因・修正・検証は一つの`solution`へまとめる
- 同じ結論の言い換えや作業ログだけの情報は保存しない
- `content`は条件と結論が分かる一文、`detail`は根拠・手順・検証、tagsは安定した名詞1〜5個にする
- `decision`にはrationaleを必ず付ける
- repository内の知見には現在のrepoとbranchを付ける

## 書き込みを承認してもらう

`upsert`または`follow_up`を呼ぶ前に、件数、対象ID、type、content、tags、decisionのrationale、変更前後の差分を一度提示し、利用者の承認を得る。承認なしに書き込まない。

createではIDを渡さない。updateでは`get`が返した明示IDとversionを`expectedVersion`へ渡し、未指定fieldを消さない。競合時は最新値を取得して差分を作り直し、再承認を得る。follow-upはInsight本体のupsertへ混ぜず、add・resolve・reopenを明示する。
