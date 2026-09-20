# start_task入力拒否と予約解除の検証

検証日: 2026-09-21 JST

## 自動解除条件

`PostToolUse`の`start_task`で所有session・非空call IDが一致し、予約の`task_id`がnullの場合だけ拒否応答を検査する。単一text JSONの`configuration_error`・`input_validation`・boolean falseの`execution_started`と、boolean trueの`isError`を要求する。重複JSONキー、不正型、複数content、structuredContent併記、未知fieldは解除しない。

## 検証結果

| 検証 | 結果 |
|---|---|
| `python3 tests/test_deepseek_worker.py` | 15件成功 |
| 拒否後の親読取りと次の正常起動・完了 | 成功 |
| task IDあり、owner/call不一致、旧error、不正応答、通信失敗、abort_error | 保護維持 |
| 既存timeout正常回収 | 解除を維持 |
| `bash tests/verify-all.sh` | `PASS=245 FAIL=1` |
| Claude/Codex配置シミュレーション | 成功 |
| suiteの失敗 | 変更対象外の既存Markdown箇条書き句点チェック |
| 独立reviewer | 起動toolに専用role指定欄がなく未実施 |

実bridgeとの接続は次で再現できる。

```sh
/Users/kaikojima/Desktop/develop/deepseek-bridge/.venv/bin/python tests/probe_deepseek_rejection.py --bridge-root /Users/kaikojima/Desktop/develop/deepseek-bridge
```

新規processの実MCP入力拒否から配布hookの解除・親読取り許可まで成功した。使い捨てrepositoryと隔離stateを使い、モデル実行は開始しない。Pre/Postはprobeによる手動配送であり、Codex自動配送は未確認。

確認したbridge `src/deepseek_bridge/server.py`のSHA-256は`467495e639ee426ae66f1155177edf97d97a634806a01564e8a6ec0fecac263d`。

## yoriの限定反映・個別復旧

- 対象: `/Users/kaikojima/Desktop/develop/yori`
- owner: `01a0c075-0f64-7800-a594-06da32104747`
- call ID: `exec-c605feb4-0163-4ecb-b32f-97a705577a5a`
- 初回task: `task-2c4e406d95c84660b0eec2834d0f0d9d`
- 元の入力検査失敗、初回`task_timeout_error`終了、印なし旧error、所有者・call・現在予約を照合
- 所有タスクidle、yoriの既存bridge PID 22028に子processなしを復旧直前に確認
- ロック下で予約全体を完全一致検査し、不一致5種類の拒否を確認
- 一回限りの復旧script: `/tmp/recover-yori-input-rejection.py`
- 旧応答は再処理せず、退避後に同じ予約の`busy`だけfalseへ更新
- 退避: `.codex/tmp/deepseek-worker.exec-c605feb4-0163-4ecb-b32f-97a705577a5a.before-recovery.json`
- 配布反映は`.codex/hooks/shell/deepseek-worker.py`の1ファイルだけ
- 配布元との一致、`busy=false`、親読取りhookの許可、確認前後の状態不変を検証
- yoriの既存bridgeは再起動していないため、そのprocessの新契約反映は未確認

通常の自動解除条件は緩和していない。配布元へのbootstrap、アプリ処理、担当承認ルール、bridge本体の変更は行っていない。
