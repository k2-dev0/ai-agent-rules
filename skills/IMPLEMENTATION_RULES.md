# 設計・実装・レビューの判断基準

開始時に該当規約と最寄りの同型実装・caller・export・依存・test/mock方式を確認し、配置・命名・宣言順を合わせる。規約の例からpathやlibraryの存在を仮定しない。

配布先は`.[agent_name]/rules/`、配布元は`rules/`を基準にする。

| 対象 | 規約 |
|---|---|
| TS/JSの関数・型・配置 | `typescript/function-pattern.md` |
| 入力検証・schema | `typescript/validation-pattern.md` |
| API・DBアクセス | `typescript/api-pattern.md` |
| DB schema | `typescript/db-pattern.md` |
| 日付 | `typescript/date-pattern.md` |
| UI | `typescript/ui-pattern.md` |
| test | `typescript/tdd-pattern.md` |

明示要件と実装手段を区別し、実装と矛盾する古い規約・設計案は訂正する。承認済みの挙動変更はユーザー判断へ戻す。適用規約・既存例・矛盾の解決を簡潔に記録し、委任briefにも渡す。

## 構造

- 現在の要件とconsumerに必要な要素だけ追加する（YAGNI）。テスト専用export・Client差し替え引数・ClientLike型・薄いwrapper・将来用configは作らない。同一file内もconsumerとし、公開範囲を不必要に広げない。
- 一度だけ使う処理は原則インライン。独立した入出力・責務があり、主処理を読みやすくする場合だけ切り出す。行数・ネスト数だけで分割せず、複雑な条件は名前付き変数にする。
- 共通化は同じ責務・変更理由を持つ場合だけ。`utils.ts`を機械的に新設しない。
- HTTP・file・外部APIの未検証入力は境界で検証する。検証済み内部値へ根拠のない型拡張・重複guard・黙ったfallbackを加えない。
- 制御フローとdata変換を上から追える構造を選び、不要な関数ジャンプを増やさない。多少冗長でも局所的に理解できる記述を使う。
- テスト・型検査と、構造・配置・命名は別々に判定する。consumer、単純な代替、同責務の既存例を確認する。

## 実行境界

endpoint・queue・scheduler・worker・serverless・外部接続・global/shared変更は、既存の実行方式と最小限の永続化だけの基準案で満たせない明示要件または既存制約がある場合だけ採用する。対応要件・代替案・不足箇所のコード根拠を示す。未要求の即時性・性能・将来拡張性で追加しない。
