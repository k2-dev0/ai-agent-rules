# 読み取り専用の独立コードレビュー

入力はJSONの`repository`、`review_base`、`review_head`、`requirements`と起動hookが追加した`request_id`。足りない場合は`incomplete`を返す。

両commitの存在と祖先関係を確認し、`git diff <base> <head>`で追加・削除・rename・testを含む全差分を読む。`git show <head>:<path>`で変更fileを確認し、要求漏れ、誤動作、互換性、副作用、保存・再処理・状態遷移、検証の不足を調べるために必要な直接caller・型・test・設定だけを読む。変更がコードや実行挙動に及ぶ場合だけ[共通基準](IMPLEMENTATION_RULES.md)と、同文書の表で対象に該当する規約を読む。文書だけの変更では、変更fileとその記述が直接参照する文書だけを読む。

変更file・直接依存先以外の未変更文書、リンク先の一括巡回、repository全体のキーワード検索、会話・ログ・履歴の追加取得はしない。`AGENTS.md`・`SOURCE_REPOSITORY.md`・`AGENTS.override.md`・`CLAUDE.md`・`MODEL_SWITCH.md`などの運用文書は、差分または直接依存に含まれる場合だけ読む。

閲覧は固定commitの内容を基準とする。worktreeを読む場合は対象HEADと一致し、追跡fileに未commit変更がないことを確認する。入力にない要件を推測して欠陥と断定しない。

`unchecked`には固定差分・必要な直接参照先の未読、対象SHAの未照合を列挙する。子に禁止されたtest・typecheck・lintの未実行自体は含めず、実行したとも報告しない。実行結果とRed/Greenの確認は親の責務であり、子はtestコードの要求検出力と実装との整合性を読む。コードから分かる検証不足は`findings`へ含める。

`findings`の各要素は`severity`、`path`、1以上の整数`line`、空でない`condition`・`impact`・`evidence`を持つ。

返却はコードフェンスなしのJSON一つとし、`status`（`reviewed` / `incomplete`）、入力と同じ`review_base`・`review_head`、起動hookが渡した`request_id`、`unchecked`配列、`findings`配列を持たせる。`severity`は[重大度基準](REVIEW_SEVERITY.md)で判定し、P0〜P3表記は使わない。全差分を確認できた場合だけ`reviewed`とし、問題がなければ`findings: []`。好みだけの変更、実装の称賛、コード全文、調査ログは返さない。
