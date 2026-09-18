# DeepSeek MCP 非同期hook実機検証

検証日: 2026-09-18。時刻はUTC。比較元: `5e60c0073f72209bc1b6735fee27f53e8768ecc1`

## 結果と適用範囲

Codex 0.155.0の新規検証セッションで、通常完了・短縮timeoutとも次を直接観測した

- `functions.exec`の`yield_time_ms=1`と`Script running with cell ID 1`
- そのcellへの`functions.wait`と最終`Script completed`
- 内側のMCP `wait_task`は各1回
- 実MCP終了結果に対するPostToolUseの`hook/completed`
- 同じtask・ownerの`busy=true`から`false`への遷移
- 同一検証セッション内の親読み取りに対するPreToolUse成功と終了コード0

外側の記録はCodex標準rollout、内側の結果・hook実行はapp-server通知、保護状態は読み取り専用観測で照合した。hook手動呼出し・保護状態の直接書換えは行っていない

最初のデスクトップセッションは0.155.0-alpha.9。実DeepSeekの通常完了とcell 10/25のyieldは観測したが、保護状態が作られず、自動配送成功には数えていない。新規0.155.0セッションの結果から、この稼働中デスクトップセッションへ修正が反映されたとは推定しない

## 前提不備と修正

`hooks/list`でローカルPreToolUseは`modified`、PostToolUseは`untrusted`だった。ユーザー承認後、この2定義の信頼ハッシュだけを更新した。検証セッション起動時には両方`trusted`を確認した

登録・ローカルhook本体は既存の配布元と一致。配布hook・bridge本体・通常bridge設定・アプリ・担当規約は変更していない。元セッションでの欠落原因をyield配送の不具合とは断定しない

## 通常完了

| 項目 | 観測値 |
|---|---|
| Codex session | `01a0b39f-e429-7951-ac7a-0d158b758c0b` |
| task | `task-37ccd773cf6f48539eaea17d472da3de` |
| 内側start呼出し | `exec-6f221d2e-b5c2-40ae-a7fc-deb104c1aa9b` |
| 内側wait呼出し | `exec-3c1cd780-0837-46b0-867a-da853cb595e6` |
| 外側exec呼出し | `call_9bI3yvcLosJinBGkD10MK9td` |
| cell / yield時刻 | `1` / `08:26:46.566` |
| 外側wait呼出し | `call_NBllKsT9n6BXd5YwNYycgq94` |
| 終了結果 | `completed`、3,041 ms、`08:26:49.703851` |
| PostToolUse完了 | `08:26:49.799108`、`completed`、94 ms |
| busy=false観測 | `08:26:49.798524` |
| 外側wait完了 | `08:26:49.799` |
| 親読み取り | `exec-310730fc-dd44-4d52-9bac-36b1c099e719`、終了コード0、`08:26:54.258297` |

## 短縮timeout

| 項目 | 観測値 |
|---|---|
| Codex session | `01a0b3a1-6a47-7fc3-97f4-c6e43ea33c72` |
| task | `task-cb92f6b577f44b819286203957ae3f1c` |
| 内側start呼出し | `exec-4faa78e8-99ff-4cfb-9c26-8ae86bf02662` |
| 内側wait呼出し | `exec-b7ed0b73-35de-4686-baca-8326a307211a` |
| 外側exec呼出し | `call_gdiCHePcHZsMZ6j2GanJ1yRB` |
| cell / yield時刻 | `1` / `08:28:27.087` |
| 外側wait 1 | `call_9jotNiiBYUTLdseFcE4q9oVZ`、`08:28:30.848`に同じcellで再yield |
| 外側wait 2 | `call_AzTKmhmlZRU30UkEEvAPBGHs` |
| 終了結果 | `failed` + `task_timeout_error`、7,132 ms、`08:28:34.316653` |
| PostToolUse完了 | `08:28:34.410116`、`completed`、92 ms |
| 外側wait完了 | `08:28:34.410` |
| busy=false観測 | `08:28:34.431117` |
| 親読み取り | `exec-efe8016b-c1d3-46fe-9567-7ad72f19fd27`、終了コード0、`08:28:37.299545` |

外側waitの継続2回と、内側MCP waitの1回を区別している

## fixtureと再実行条件

`tests/probe_deepseek_async_server.py`をbridgeのvenv Pythonで起動する。`--bridge-root`に実bridge repository、`--scenario`に`completed`または`timeout`を指定する

実stdio MCP server・TaskManager・watchdog・Runtime・DSHを使用し、外部モデルだけをbridge既存のSSE fixtureで置き換える。通常は`sleep 2`、timeoutは`sleep 30`を要求し、専用プロセス内だけでhard/inactivity期限を5秒にする。キーはfixtureのcanary、stateは一時ディレクトリ。HTTPはサンドボックス外で実行する

Codex起動引数でMCP command/args/env_varsをこのfixtureへ一時的に上書きし、`code_mode`と`code_mode_only`を有効にした。通常設定ファイルは変更しない。起動先cwdはこのrepository。最初に`hooks/list`の2定義が`trusted`であることを確認する

1つのexec内でstartをawaitし、そのtask IDで直ちにwaitを1回awaitする。execの先頭は`// @exec: {"yield_time_ms": 1}`。返されたcellだけを外側waitで完了まで待つ。最後に同じセッションで状態fileとGit状態を読み取る

fixture単体のstdio疎通成功、検証セッションの最終報告だけ、別ownerの読み取り成功は自動配送の証拠にしない

## 回帰・回収・残件

- `python3 -m unittest discover -s tests -p test_deepseek_worker.py -v`: 12件成功。不一致・abort_error・終了未確認の保護維持を含む
- `bash tests/verify-all.sh`: `PASS=246 FAIL=0`。Claude/Codexの配置シミュレーションを含む。配布元自身へbootstrapは実行していない
- fixture単体も通常完了・task_timeout_errorを確認。これはhook自動配送とは別の検証
- 検証用Codex/app-serverは終了コード0で終了。専用bridge/DSH/観測プロセスの残存なし
- 終了後に一時stateディレクトリ5個の残存を検出。関連プロセスの不在確認後に回収し、残数0。通常bridgeの終了処理へ変更を持ち込んでいない
- 一時制御script・生成schemaを回収し、記録付き検証セッション2件はarchive。ID・状態・時刻だけの診断証跡を`/tmp/deepseek-async-verified-evidence.json`に保持
- 最終保護状態はtimeout taskに一致する`busy=false`、`observations={}`
- fixture実装workerはfile作成後に`task_contract_error`で終了。その報告を成功根拠にせず、実fileの構文と実行を検証した
- fixtureの独立レビューは未実施。現在の子起動APIには必須の`code-reviewer`専用role指定欄がなく、汎用子で代用していない
