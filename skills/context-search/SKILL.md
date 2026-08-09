---
name: context-search
description: context-dictionary API から過去の知見を検索・取得し、現在の作業に活用する。
allowed-tools: Bash
disable-model-invocation: true
---

## 実行

引数があれば検索意図として使い、なければ何を探すか一度だけ尋ねる。`../context-api/API.md`を全文読み、次の順で最大3回検索する。

1. 元の語句を全文検索へ渡し、現在のrepoと、意図から一意に決まるtypeだけを付ける
2. 3件未満ならtypeを外し、同じ語句を現在のrepo内で検索する
3. まだ3件未満なら語句を2〜4個の固有名詞へ縮め、repo指定なしで検索する

各検索は10件まで取得し、IDで重複を除く。完全な語句一致、同じrepo、type一致、更新日の新しさの順で並べ、上位5件を返す。0件なら検索段階と語句を示して終了する。

結果はtype、日付、contentを示し、存在する場合だけdecisionのrationale、未解決followUps、relationsを添える。生JSONを返さない。serverへ到達できなければ通知して終了する。
