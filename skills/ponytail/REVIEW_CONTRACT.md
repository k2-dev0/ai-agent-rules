# 独立設計レビュー契約

入力はrepository絶対path、元の要件・禁止制約・受入済みtrade-off、要件revision、設計revision、対象index・設計書pathと内容hash、参照コードのHEAD。入力不足は`blocked`。設計書だけから元の要件を推測しない。

[判断基準](../IMPLEMENTATION_RULES.md)・該当規約と既存コードを読み、要件と設計を照合する。実装・設計会話、親のログ、前段の結論、過去のレビュー結果を取得しない。入力の全対象とhash・HEADを確認し、不一致・未読範囲があれば`blocked`。参照コードに未commit変更があれば`blocked`。指定された設計書・indexは未commitでもhashが一致すれば読める。

編集・Git変更・外部通信・install・test実行・モデル変更・再委任・承認要求は禁止。shellは読み取り・検索・hash確認だけに使う。最終結果だけ返し、中間ログ・コード全文は返さない。

## 手順

1. 個別設計書より先に一式を横断し、入口、共有責務、全caller・consumer、永続化、外部副作用、利用者の契約を追う。bug修正では報告された症状とroot causeを分ける。
2. 省略 → 既存実装・実行方式 → 標準library → native機能 → 導入済み依存 → 最小の独自実装の順で比較する。要件を満たす案が見つかったら、それ以降は追加しない。
3. 境界・global/shared変更を増やさない案と比較し、下表を埋める。新設要素のためだけの要素、導出できる定数、設計選択だけに対応する要素は削除候補にする。
4. 数値・順序・候補選択は具体値で反証する。自動選択・先頭N件・min/max・tie-break・組み合わせ探索の未指定部分を要件へ昇格させない。
5. 再利用候補の引数・戻り値・副作用・error・運用範囲、runtime・browser・DB・frameworkの対応version、依存の利用方式を確認する。新設要素は設計上の直接consumerと既存責務を照合し、未実装という理由だけでは停止しない。
6. [設計書形式](../cowlick/DESIGN_FORMAT.md)と照合し、設計書・indexの修正候補を指摘として返す。編集しない。
7. 全対象を確認し、statusと監査結果を返す。

| 特に確認する新設要素 | 判断 |
|---|---|
| global middleware・認証認可・logger・router・shared schema、endpoint・queue・DLQ・scheduler・worker・serverless・外部接続・deployment・監視復旧 | 共通判断基準で必要性を確認。根拠がなければ削除候補または相談 |
| 実装が一つだけのinterface、一製品factory、一caller layer、委譲だけのwrapper、固定config | 直接の責務へ統合できるか比較 |
| caller別のguard・workaround | root causeの共有責務へ統合。統合できなければ既存制約と他経路への影響を確認 |
| 新設要素が生む失敗と緩和策 | 原因と対で削除できるか比較 |

受入済み要件・trade-offを覆さない。挙動、入力境界、error、data loss防止、security、accessibility、整合性、互換性が変わる案は相談する。非自明な分岐・loop・parser・金額・securityを守る最小の実行可能なテストを削らない。

## 必須監査成果物

最終結果に入力の要件revision・設計revision・全対象pathとhash・HEAD・未確認範囲と`ponytail_audit`を含める。ファイルは増やさない。

| field | 内容 |
|---|---|
| `revision` | 対象design revision |
| `requirements` | 明示要件／禁止・制約／受入済みtrade-off／既存制約／設計選択 |
| `topology` | 入口、caller・consumer、共有責務、永続化、外部副作用、既存・新設境界、症状とroot cause |
| `elements` | 新設file・export・関数・定数・型・class、対応要件、直接consumer、単純な代替、配置・命名・exportの既存例、失敗と緩和策、残す／統合／削除、根拠 |
| `minimalAlternative` | 境界・global/shared変更を増やさない案との要件充足・trade-off・失敗・運用負荷の比較 |
| `counterexamples` | 数値・順序・選択規則の具体値・期待結果・根拠。等号、混在、同値、入力順、候補不足を該当分だけ確認 |
| `limitsAndTests` | 性能・容量・並行性・精度・運用の上限、再検討する測定可能な条件、最小の実行可能なテスト |
| `changesContract` | 設計書形式の必須sectionとChangesの実装情報を保持 |
| `unresolved` | 未決定事項。ready時は空配列 |

一つのfindingはIDを付けて一度だけ説明し、他fieldではIDを参照する。同じ要件・原因・判断・置換先を持つ要素は一行へまとめる。同じtopologyや根拠を別fieldで言い換えない。非該当fieldは理由付き`not_applicable`を一行で示す。

## 成功・返却

全fieldが埋まり、`unresolved`が空、revisionが現在のdesignと一致し、要修正の指摘がない場合だけ`ponytail_ready`。残した要素には対応要件・直接consumer・単純な代替では満たせない根拠が必要。

| status | 条件 |
|---|---|
| `ponytail_ready` | 上記条件をすべて満たす |
| `changes_requested` | 設計書・indexに修正が必要 |
| `consultation_required` | 挙動変更などのユーザー判断が必要 |
| `blocked` | 設計書の不整合・要件由来・参照先・必須根拠の不足 |

選んだ案、削除・統合・再利用、残る上限を簡潔に報告する。項目は`[delete|reuse|stdlib|native|yagni|shrink] 対象 → 置換先（path:line）`で示す。何も削らなかった場合も、比較案と満たせない要件を返す。未実装案の削減行数・工数・費用を実測値として示さない。

未決定事項は選択肢・挙動差・推奨を返し、直接質問しない。最終承認・反映phaseは追加しない。
