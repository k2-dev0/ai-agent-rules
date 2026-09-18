# DeepSeek bash停滞の切り分け

検証日: 2026-09-18。配布元比較元: `c6e5084f433d98711028ce7d76b3a705979ca296`。
bridge採取時HEAD: `7ec3af8`。SDK/runtime: `0.1.5rc1`、macOS arm64。

## 結論

- **配布側の保護を必要としない停滞を再現した。** `env -i`、PTY、`core.pager=delta`、端末へ出力する`git log`の組合せで、`bash → git → delta → less`が残り、コマンド完了マーカーとSDK `tool/result`が返らない。
- 通常bashでもPTYでは待ち、パイプ出力では完了した。PTYへ`q`を送ると終了コード0で完了した。SDK特有のコマンド投入障害とはいえない。
- これは対象4の構造と利用先のpager設定に一致する。ただし、元の停止時のプロセス・PTY記録はないため、対象4そのものの原因確定とはしない。
- heredoc3件は再現できず原因未確定。全4件をpager待ちで説明しない。
- Git環境の部分継承は別に再現した。配布処理は7組を設定するが、DSHが`GIT_CONFIG_KEY_n`を除去し、COUNTとVALUEを残す。Gitは即時128で終了し、その後のbashも動く。これだけでは停滞しない。
- 配布元のbash停滞原因を確認できなかったため、配布コード・通常設定・利用先は変更していない。保護解除・期限修正の成功をbash停滞解消の証拠にしていない。

## 履歴の確認

ローカル`session.v3.jsonl`をメモリ内で解析した。プロンプト、モデル応答、元のファイル本文は証跡へ転記していない。

| 対象taskの短縮ID | sessionの短縮ID | 最後のbash: 文字数 / 行数 | call / result総数 | 直前の結果 |
|---|---|---:|---:|---|
| `9f55aade` | `3e6f845f` | 1,090 / 32 | 62 / 61 | exit 0 |
| `a43ce28c` | `1e32d1e8` | 1,115 / 33 | 27 / 26 | exit 0 |
| `43f3f0e0` | `154e9545` | 18,625 / 487 | 20 / 19 | exit 0 |
| `e61f1491` | `e4d29bac` | 188 / 1 | 18 / 17 | Git missing config key、exit 128 |

4件とも最後は`tool/call`、bash構文検査は0。末尾改行なし、CR・TABなし。
heredocの区切りは引用済みで閉じている。1行事例は環境名の値を伏せた列挙の後、PATH/HOMEだけを残した`env -i`で`git -C ... status --porcelain`と`git -C ... log --oneline -3`を実行する構造。Git出力をファイルへ逃がす構造ではない。

元の履歴だけで確定できる境界は「tool/callあり、対応tool/resultなし」まで。元のbash生成、標準入力投入、コマンド終了、完了マーカーは記録されていない。
モデル待ち中に止まった`task-de850876...`は集計対象外。

## 配布template・配置・稼働プロセス

3 repository（配布元、mypage-v2、bridge）の`.codex/hooks/shell/`について、以下4ファイルは配布templateとバイト一致した。

- `deepseek-launch.sh`
- `mcp-protected.sh`
- `protected-exec.py`
- `git-safe-env.sh`

設定上の経路は`bash → deepseek-launch.sh → mcp-protected.sh → git-safe-env.sh → python3 -I protected-exec.py → sandbox-exec → bridge`。
実験では使い捨てrepositoryへコピーしたこの経路を実際に通した。配布元自身へのbootstrapは実行していない。

`git-policy.py`も3配置で一致。`deepseek-worker.py`はmypage-v2だけ不一致だった。これは別途修正済みとされる保護解除処理の配置差であり、今回のbash停滞の原因としない。`hooks.json`の生バイトも一致しないため、template一致だけで稼働hookの信頼・適用状態まで保証しない。

調査開始時、配布元のworker状態は`busy=false`、bridge側には別taskの`busy=true`と実DSH/bashが存在した。既存taskの継続・取消・保護状態書換え・編集は行わず、ソースを一時領域へコピーして実験した。MCPの4操作はALL_TOOLSで解決できることを確認したが、既存bridgeへ実験taskは投入していない。

期限修正`9a7e4a4`は18:22:13 JST。プロセスのcwdと起動時刻を照合すると、少なくとも以下の古い候補が残っていた。

| PID | cwd | 起動時刻 JST |
|---:|---|---|
| 51288 | mypage-v2 | 15:40:07 |
| 74246 | deepseek-bridge | 16:55:51 |
| 47253 | ai-agent-rules | 17:07:34 |

bridge側には18:23:02以降の候補も存在した。稼働プロセス内部の定数は読み出していない。旧プロセスへの修正ロード済みとは判定せず、再起動もしていない。今回のfixtureはコピーした新しいソースを新規プロセスでロードした。

## 実験条件

一時領域: `/private/tmp/deepseek-bash-investigation`。
実bridge Runtime、実SDK、同梱DSH、既存`test_privacy_wire.py`のローカル模擬APIを使用。実モデルへの通信は行わない。
親からの環境はPATH・fixture専用HOME/TMPDIR・locale・固定canaryだけを明示設定し、実API keyとユーザーのrcは渡していない。
HTTPと保護付き起動は外側sandboxから実行した。

- 通常ケースのrun待機は8秒。連続65回だけ45秒、外側プロセス上限55秒。
- SDKのclose、run thread join、必要時の所有プロセス強制終了、fixture固有プロセスグループの回収を実施。
- bridge本体・通常watchdogの期限は変更していない。
- 観測器はfixture内の追加DSH plugin。`spawnTerminal`・stdin writeを元の実装へそのまま転送し、PTY出力からOSC `133;D`完了マーカーだけ検出する。出力本文は保存しない。
- 診断は固定ラベル、時刻、PID、終了コード、個数、真偽値だけ。SDKが一時stateへ作った合成会話の履歴は実験後に削除した。

初回fixtureはstateをworkspace内に置いたため、privacy検査でSDK起動前に失敗した。これはbash停滞でも成功でもない。stateをworkspace外へ移して、下記の実行を行った。

## 経路比較

時間は原則tool/callからtool/resultまで。表の「応答」はコマンド成功と区別する。Git環境不整合でもエラー結果は返る。

| 入力・条件 | 通常bash（pipe） | 実SDK | Git保護環境のみ + SDK | 配布保護経路 + SDK |
|---|---|---|---|---|
| printf | exit 0 | 956 ms | 667 ms | 666 ms |
| 32行の合成heredoc | exit 0 | 670 ms | 681 ms | 659 ms |
| 487行の合成heredoc | exit 0 | 578 ms | 582 ms | 579 ms |
| env -i + Git、出力file | exit 0 | 674 ms | 657 ms | 653 ms |
| Git通常継承 | exit 0 | 応答715 ms | エラー応答680 ms | エラー応答673 ms |
| 環境個数観測 | exit 0 | 657 ms | 668 ms | 668 ms |
| 同一session内65回 | — | 65/65、11.092秒 | — | 65/65、11.177秒 |
| env -i + delta + Git端末出力 | exit 0 | 8秒で未応答 | — | 8秒で未応答 |

追加のheredoc比較では、元の本文を非空白文字ごとに`x`へ置換し、本文の行数・行長・空行を維持した。引用された区切り、リダイレクト、末尾改行なしを再現した。実アプリのパス・本文・後続処理は再現せず、fixtureの開始/終了マーカーに置換した。実コマンド全体の完全再演ではない。
この3種と1行の対照の計8実行は、通常SDK・保護付きSDKで666–876 ms以内に応答した。シェル生成・stdin投入・完了マーカーも観測した。

最初の`env -i`対照は出力をfileへリダイレクトしていた。これではpager条件が失われる。その成功だけで対象4を非再現と結論づけず、端末出力とpagerを加えた再試験を行った。

## 再現した停滞の境界

fixtureのGit設定を`core.pager=delta`にし、`env -i`でPATH/HOMEだけを残して`git log --oneline -3`をPTYへ出力すると、2回の独立した比較で通常SDK・保護付きSDKとも未応答になった。
詳細観測した8秒時点の子プロセスは次のとおり。

| 経路 | runtime | bash | git | delta | less |
|---|---:|---:|---:|---:|---:|
| SDK | 50808 | 50819 | 50843 | 50844 | 50850 |
| 保護付きSDK | 51079 | 51080 | 51096 | 51097 | 51103 |

両方ともシェル起動成功、初期マーカーあり、対象入力のwrite完了。**対象コマンドの完了マーカーは期限時点でなく、tool/resultもない。** 子プロセスの終了をSDKが見落とした事例ではなく、子がまだ残る事例だった。
close後のマーカー・fileの存在を、期限前にコマンドが完了した証拠に数えていない。

`--no-pager`を加えるfixture対照は両経路で応答した。さらにSDKを外した通常bashの比較は以下。

| 通常bash条件 | 結果 |
|---|---|
| pipe | 35 ms、exit 0 |
| PTY | 3秒で未終了、専用process groupを回収 |
| PTYで1秒後に`q` | 1.031秒、exit 0 |

これはpagerの入力待ちを支持する。`--no-pager`や再試行を全件の根本修正とは扱わず、fixture上の因果確認にだけ使用した。
SDK同梱コードのmacOS `isStdinWaiting()`は常にfalseを返す。この制約とpager待ちの通知契約はSDK側の確認対象であり、本調査でSDKを修正していない。

## Git環境の独立した不整合

同じfixtureで、配布起動後のPythonはCOUNT=7 / KEY=7 / VALUE=7、DSH bash内はCOUNT=7 / KEY=0 / VALUE=7だった。OS保護なしでも同じ。
SDK同梱コードの`SENSITIVE_ENV_PATTERN = /KEY|PASSWORD|SECRET|TOKEN/i`と`scrubbedParentEnv()`がこの変化と一致する。Python SDKの起動側は親環境をcopyして追加envをmergeしており、組を削除していない。

| 通常Gitの環境 | 結果 |
|---|---|
| 全7組が整合 | exit 0、21 ms |
| KEYだけ除去 | missing config key、exit 128、15 ms |
| VALUEだけ除去 | missing config value、exit 128、16 ms |
| COUNTだけ除去 | exit 0、18 ms（設定組は適用されない） |
| env -i | exit 0、16 ms |

COUNTを単に消す案はGit保護用設定も失うため採用していない。SDKの秘密除去を緩める修正も行っていない。

補助プロセスの別対照では、fixtureの`core.fsmonitor`に固定マーカーだけを出す有限helperを設定した。配布Git環境ではhelper未起動、env -iでは起動した。利用先2 repositoryの実効設定ではcore.fsmonitorは未設定、core.pagerはdeltaだった。値の全件出力はしていない。
したがってenv -iはGitエラーを消せても、抑止していたhelper/pagerを再び有効にし得る。

## 秘密を含まない再現手順と証跡

ローカル成果物: `/private/tmp/deepseek-bash-investigation-artifacts.zip`。
内容は診断script、合成入力、固定ラベルの結果・観測記録、採取ソースのSHA-256 manifest。元session、認証情報、実プロンプト、元のファイル本文、実アプリのcopyは含まない。

archiveを**新しい空の一時directory**へ展開する。scriptはこの端末のbridge/rulesの絶対pathを使用する。別端末ではscript先頭のBRIDGE/RULES/PYTHONをインストール先へ合わせる。

1. bridgeのvenv Pythonで`setup.py`を実行する。ソース・既存模擬API・hookを一時領域へコピーするだけで、実repositoryは変更しない。
2. 同じPythonで`phase5.py`をsandbox外で実行する。使い捨てGit repositoryにdeltaを設定し、実SDK/保護付きSDKのpager待ちと`--no-pager`対照を比較する。外部モデルへは接続しない。
3. `shell-pty.py`をsandbox外で実行すると、通常bashのpipe/PTY/終了キー対照を確認できる。
4. `phase5-results.json`のcalls/results、`owned_child`、`observer_at_deadline`、`reclaimed`を確認する。fixtureプロセスの外側exit 0だけをコマンド成功とみなさない。

`probe.py`は初期経路比較、`phase2.py`は65回比較、`phase3.py`は本文長を合わせた入力と意図的な待機、`phase4.py`は最初のpager再現。正常ケースの固定ラベル証跡も保存した。
再実行時も短い期限、所有PID/プロセス群の回収、HTTPのsandbox外実行を維持する。通常の保護環境やユーザーのHOMEを実験用に変更しない。

## 変更・回収・残件

- 追跡対象の変更はこの調査記録だけ。配布物の修正・利用先反映・bootstrapはなし。したがって修正前後の回帰テスト・Claude/Codex再配置検証は対象外。
- 保護付きfixtureの実行成功は、通常Codexのhook信頼・非同期PostToolUse配送を再検証した証拠ではない。
- 全実験のrun thread回収とruntime終了を確認。8秒で打ち切ったケースもclose後にruntime exit 0。これは実コマンド完了の成功値ではない。
- 最終回収で記録済みruntime/bash/git/delta/lessのPID残存と、一時領域をcwdとするプロセス残存を確認し、結果を`cleanup-check.json`へ保存した。fixtureのstate・repositoryを削除し、再現入力・scriptと秘密を含まない証跡だけを残した。
- heredoc3件の原因、元sessionでの正確な子プロセス/入力状態、稼働bridge内部の期限定数は未確定。今回の合成入力は元sessionの全履歴・シェル状態・アプリ処理を再演していない。
- SDK/bridgeへの引継ぎ対象は、(1) Git設定組の部分除去、(2) macOS PTYでpagerが待つ場合のtool結果/期限契約、(3) 次回実障害での本文を保存しない起動・stdin・マーカー観測。bridgeの期限・診断実装は別タスクのままとする。
