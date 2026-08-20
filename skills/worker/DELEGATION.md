# worker委任の共通契約

session最初の委任前に`bash [skills_root]/worker/delegate.sh prepare`を実行する。初回はhookがこの文書を注入して停止する。内容を反映して再実行し、後続委任では繰り返さない。

通常の委任では、モデル選択用の`DELEGATE_MODEL` / `DELEGATE_MODEL_VARIANT`を**絶対に付けず**、裸の`bash [skills_root]/worker/delegate.sh`で呼ぶ。モデル変更をユーザーが明示した時だけ環境変数を使う。

## 上位モデルとworkerの境界

| 担当 | 責務 |
|---|---|
| worker | コードベースの読み取り専用調査と根拠収集 |
| 上位モデル | 依頼、設計・要件判断、調査結果の採否、実装subagentの統括、修正、test、Git |

workerへは`delegate.sh`だけを使い、`research`、`survey`、`nesting`以外の仕事を渡さない。コード、test、schema、設定、設計書の作成・変更、実装案の生成、test failureの修正をworkerへ依頼しない。同じ調査を並行委任しない。

## 委任前の判断

- `survey`は、一つの変更判断に必要な最小の事実だけを聞く。入口・入力・変換・保存・testなどを一つのclaimへ詰め込まない。
- 旧revisionと現在を比較するなら別taskにする。依頼のJSON schema、CLI引数、timeoutはrunnerの検証に従う。

## 結果の扱い

`evidence_status: verified`で現在blobが一致する根拠は、同じ箇所を読み直さない。不足は`next_action`に従って限定surveyし、初回を含め三回で止める。前回の未検証結論を事実として渡さない。
productionを直接調べるのは、認証失敗、同じ依頼の通信・report失敗が二回、三回の調査後も必須情報が不足、snapshot外の状態、高リスクな独立確認、またはユーザーが明示した時だけにする。理由と、再surveyより有利な理由を残す。広域探索やfile全体のReadはしない。
`worker-result`の`failure-class`と`next-action`で次の行動を決める。smokeはユーザーが明示許可した時だけ実行する。
runnerはworkerの読み取り専用隔離、依頼・出力・Evidence形式、timeout、retry / repair / supplement の上限と系譜を強制する。ここに同じ細則を書かない。
