## 入力・対象

元の要件・禁止制約・受入済みtrade-offの本文または正本path、要件revision、設計revision、対象の`.[agent_name]/prompt/.prompt.md`と参照先設計書を受け取る。設計書だけで要件を代用しない。不足は`blocked`を呼出元へ返す。

## 起動・待機

子の起動直前に[子・待機の規則](../SUBAGENT_RULES.md)を読む。

1. repository絶対path、参照コードのHEAD、対象index・全設計書のpathとSHA-256を保持する
   - 対象設計書以外の参照コードに未commit変更があれば`blocked`
   - 設計書のcommitは要求しない
2. briefは上記対象・revision・元の要件と制約だけ
   - 前段の調査結果・作成経緯・採用理由・会話要約・過去のレビュー結果を渡さない
3. 専用`design-reviewer`を新規起動する
   - Codexは`agent_type: "design-reviewer"`と`fork_context: false`または`fork_turns: "none"`、Claudeは`subagent_type: "design-reviewer"`
   - model・effortは専用定義を使う
4. 完了後は子を終了・解放する
   - 対応role・toolが利用不能、拒否、中断なら`blocked`
   - 同じ会話内の確認で代用しない

## 結果・修正

結果のrevisionと入力対象を照合し、HEAD・全対象hashが変わっていれば結果を破棄して対象を固定し直す。

- `ponytail_ready`：[返却契約](REVIEW_CONTRACT.md#必須監査成果物)の「必須監査成果物」「成功・返却」を読み、全field・非該当理由・完了条件を検証して呼出元へ返す
  - 欠落・条件不成立は`blocked`を返す
  - 全差分の自己レビューは行わない
- `changes_requested`：メインが指摘の根拠を確認し、メインモデル選択基準に従う
  - 採用分は[cowlickの手順](../cowlick/PROCEDURE.md)を読み、現在の設計書・indexへ反映し、新revision・hashで新規レビューする
  - 子へ編集を委任しない
- `consultation_required`：要件・公開挙動・受入済みtrade-offの変更は、選択肢・挙動差・推奨を呼出元へ返す
  - ユーザー判断を代行しない
- `blocked`・対象不一致・未確認範囲あり：未完了として理由を返す
  - 指摘なしと扱わない

却下は根拠を短く残す。要修正指摘が残った結果をメインの判断だけで`ponytail_ready`へ変更しない。却下だけで入力が変わらない場合は、未解決の判断として呼出元へ返す。同一入力の再起動は行わず、要件・設計・参照コードが変わった場合だけ新規レビューする。

返却はstatus、要件・設計revision、対象path・hash・HEAD、監査結果、採用・却下・未解決事項だけ。監査基準の正本は[子専用契約](REVIEW_CONTRACT.md)とし、メインは指摘対応に必要な部分だけ参照する。
