# Context配信検証

## 2026-09-17追加: 実bridgeとの統合

実bridgeとDSH 0.1.5rc1を配布の起動script・Git保護wrapper・非同期hookへ接続し、ローカル模擬APIで編集・unittest・Git書き込み拒否・同session継続・401・実shell取消を確認した。回収失敗のfault injectionでは、`failed + abort_error`を受けた親のwriter制限が維持されることを確認した。

Macのsetuid `/bin/ps`問題はbridge側のlibproc互換処理で解消し、保護wrapperは維持した。API keyは環境変数を優先し、未設定時は`.zshrc`を出力抑止して読み込む。値をTOML・引数・logへ書かない。

ユーザーの設定したkeyで、固定短文の公式API疎通（HTTP 200、10 tokens）と、保護付き実MCP/DSH経路の`deepseek-flash` / `max`疎通（期待JSON、completed）が成功した。後者は空の一時repositoryだけを使い、ユーザーコードを送っていない。長時間開発の品質・provider側の保存方針はこの結果に含めない。

## 2026-09-17: CodexのDeepSeek委譲への移行

Codexは難度評価・deep-reviewer・nesting-reviewerを廃止し、code-reviewerとdesign-reviewerをAstra / xhighへ統一した。主担当modelは固定せず、機械的変更は現在値を維持する。Claudeの配布は従来動作を維持する。

`test_role_runtime.py`の7件をsandbox外のローカル模擬APIと実CLIで実行し、両roleのmodel/effort要求・native metadata・配布契約・レビュー受理、未信頼・準備失敗・未対応切替・index復元を確認した。実モデルの判断精度を確認した結果ではない。

`test_deepseek_worker.py`は模擬MCP結果で変更前HEAD、非同期予約、親の編集・commit・子起動拒否、結果の所有者・task・call照合、旧wait拒否、取消、状態path alias拒否を検査する。実bridgeは別タスクで開発中のため、DSHとの接続・privacy・継続・停止は未検証。旧difficulty/workflowの実モデルprobeは現動線の根拠に使わない。

## 旧版: 2026-09-16の暗号化輸送と実行経路の修正

アプリ内蔵Codex 0.154.0-alpha.6.2で、正しい2キーJSONを渡してもPreToolUseには暗号化されたmessageが届き、旧hookが子の開始前に拒否することを再現した。検証済み入力を固定し、生成された起動引数・native role・実child IDと結び付けてSubagentStartから渡す方式へ変更した。JSONのキー・型・4000文字制限、レビューのSHA・要求hash・結果照合は維持する。

実モデルの通し検査で、読み取り専用reviewerが禁止されたtest実行を未確認項目に入れる問題と、レビュー専用taskの比較元を読み取り時HEADから過去へ広げられない問題も検出して修正した。子によるtest未実行を実行成功に置き換えず、親の実行検証と子のコード確認を分ける。

重大度は`REVIEW_SEVERITY.md`へ集約し、明示要件違反だけでhighにしない。親も成立条件・直接の実害を照合する。子への基準本文の配信・欠落時の失敗と、両配布の参照を検査し、変更後の実モデル再採点までは検証していない。

| 検査 | 確認した範囲 |
|---|---|
| `verify-all.sh` | Claude/Codex両配置、bootstrap、hook・固定script・Git境界・文書参照。実モデル完走の代用ではない |
| `test_agent_input.py` | 入力形式・文字数・role/要求の差し替え・再利用・実child ID・metadata alias拒否 |
| `test_role_runtime.py` | 実CLI＋模擬APIで全5roleの起動、準備コマンドの実出力、配布hook、契約注入、model/effort要求、native metadata、結果受理。未信頼・emit故障・未対応切替も検査 |
| `test_workflow_evidence.py` | hook受理記録のない評価・不正な理由・工程逆転・未解決指摘・複数file commit・0件/skip・Green後の内容変更を成功にしない |
| `probe_agent_workflow.py --case workflow` | 実モデルで評価→test編集→Red→実装→Green→個別commit→独立レビュー受理、指摘なし、cleanを検証 |
| Baton実モデルprobe | Sol/highの拒否結果に手順を1回注入し、同じ要求の再試行後にAstra/xhighで完了した実行記録を確認 |

native CLIには`switch_model`がなく、通し検査は既存規約の降格不能時の継続を明示して検査する。これをLunaへの切替成功とは扱わない。切替対応経路はBatonの別検査で確認する。Claudeの実モデル完走、任意のdesktop設定・他versionでの同一挙動まではこの結果に含めない。

`source-review`は今回の変更を一時repositoryの固定差分にして専用deep-reviewerへ渡す。旧重大度基準でhighとされた検査器の指摘を受け、受理記録との照合・工程順序・未解決指摘・準備失敗・0件/skipの拒否と、HEAD treeからのsnapshot作成を追加した。fixtureでは指摘を自動却下せず、未解決指摘があれば非ゼロ終了する。

実モデルのworkflow成功記録は最終内容hash照合の追加前のもの。追加後はunitの異常系と、実CLIのPostToolUseで採取したfile hashを検査する。以前の記録へ存在しない観測点を補って完走済みとは扱わない。

以下は旧版の記録であり、現行版の成功証拠には使わない。

## 旧版: 2026-09-15のrole登録・開始順序の修正

Codexの配布configに各roleの`config_file`登録を追加し、シナリオ承認前に起動可否を確認する入口をTDDへ追加した。local模擬APIを使った実行器への要求比較では、登録によって`agent_type`が公開されることを確認した。

この時点の`test_role_runtime.py`はhookを無効にした実app-serverで全5roleの`agentRole`・`agent_role`とmodel・effort要求を確認しただけで、配布hookとの接続は保証していなかった。

追加の実書き込み診断ではCodex 0.154.0の子が親のworkspace-write権限を継承し、roleファイルの`sandbox_mode`と`default_permissions`のどちらでも子の書き込みを止められなかった。効かなかった設定変更は採用していない。`--probe-permissions`でこの制限を再検査でき、失敗をrole登録成功へ含めない。

## 2026-09-14の再監査後

親向けMODEL_SELECTION・SUBAGENT_RULES・INDEPENDENT_REVIEWは、起動入力を組み立てる前に正本を読む。初回起動を拒否して全文を返す配信と、文書の先読み禁止は廃止した。子の共通制約・専用契約はSubagentStartの配信を維持する。

現行の`test_context_delivery.py`は両配布の実matcherを通し、親の文書参照、native JSON入力の訂正後の起動、追送経路の拒否、子の契約欠落を検査する。`test_independent_review.py`はshell前のHEAD記録、古い結果の失効、状態保存先からGit metadataへのリンク拒否も実行する。これらはhookの動作検証であり、実モデルが手順を最後まで実行する保証ではない。

この再監査では専用roleを指定できる子起動toolがないため、汎用子を代用した実モデルの独立フォワードテストは行っていない。以下の実モデルprobeは旧版の記録であり、現行版の成功証拠へ流用しない。

## 2026-09-11の記録（旧配信方式）

行数ではなく、配線から出た文書・拒否理由のUTF-8 bytes、配信回数、宛先、再試行時の重複を測定した。全体suite内の再現テストと、実モデルを呼ぶCLI probeは別の証拠として扱う。

## 再現テスト

`test_context_delivery.py`はClaude/Codex両配布の全matcherを通す。併設環境・nested cwd・再試行・契約欠落・glob・Git参照も含む。

| 操作 | 文書注入 |
|---|---|
| 通常コード編集・文書修正・調査 | 0 |
| 明示 `tdd --from-doc` のprompt受信 | 0（skillで扱う） |
| difficulty起動前 | MODEL_SELECTION.mdと共通手順を親へ1回、操作をdeny |
| difficulty開始 | 評価契約だけを子へ1回 |
| 同じsessionで後続review起動前 | review手順だけを親へ1回、操作をdeny |
| review開始 | review契約を子へ1回 |
| 同じ内容での起動再試行 | 文書注入0 |

文書本文の見出しと実出力件数をassertし、共通手順の重複0を固定値で代用しない。request_idは入力へ追加され、別contextは増やさない。

## 実モデルprobe

Codex CLI 0.154.0、Sol/high。隔離fixtureで調査・文書修正・通常TDD・明示from-doc・独立レビューを実行した。通常TDD/from-docはシナリオ提示までの観測で、実装完了までのE2Eではない。

projectのhooks.json配置だけではイベントが0件だったため成功扱いにしなかった。同じ配線をCLIのinline設定へ渡すとhookが発火した。以下はinline経路の結果であり、project配置の保証ではない。

| ケース | 操作文書の注入 bytes | その他hookの拒否理由 bytes | CLI報告の累計input tokens | 結果 |
|---|---:|---:|---:|---|
| 調査 | 0 | 579 | 44,942 | 説明完了、変更なし |
| 文書修正 | 0 | 579 | 75,333 | typo修正完了 |
| 通常TDD（読込条件修正後） | 0 | 579 | 83,976 | 対象コード本文→共通基準→シナリオ提示 |
| 明示from-doc | 0 | 579 | 131,295 | 指定設計書を読み、シナリオ提示 |
| 独立レビュー（最終probe） | 0 | 3,003 | 556,066 | 専用子を開始できず未完了 |

input tokensは各推論への再送・cache分も含むCLI累計で、固有文書量や現在のcontext長ではない。文書読込を含む全contextが0という意味でもない。579 bytesは既存の複合shell拒否2件で、新しい操作文書の不要注入はない。

独立レビューではrole不一致の再試行が増え、利用量も増えた。別probeでは親向け操作文書の配信を確認できたが、native messageがhookからは不透明で入力照合できず、子契約の実配信まで証明できていない。親の自己確認を独立レビュー成功とは扱わない。

Claude Code 2.1.220はUserPromptSubmitの発火まで確認できたが、OAuthセッション失効でモデル呼出しが401となり、実モデル配信は未確認。

## 再実行

`python3 tests/probe_context_runtime.py <codex|claude> <case>`。caseは`investigation`、`document_change`、`normal_implementation`、`from_doc`、`review_repair`。Codexの`--inline-hooks`はproject読込不成立時の診断専用。

認証済みCLIと外部実行許可が必要。各probeは新しい一時directoryにfixture・hook-events.jsonl・runtime.jsonl・report.jsonを保存する。hook未発火、reviewの子配信なしを終了code 2として区別する。Claude再認証と、Codexのproject hook読込・専用role/本文の観測可能な起動経路を確認した後、親子配信の実機検証を再実行する。

## Baton PreModelSwitch

配布hook単体と`/Users/kaikojima/Desktop/develop/baton`の実`loadPreModelSwitchHooks`・`runPreModelSwitchHooks`を接続して確認した。Baton本体の対象テストは12件成功。さらに実モデルprobeで、旧Solの失敗したtool結果とruntime履歴に4,160 bytesの本文が1回だけ入り、同じSolが同一要求を1回だけ再試行し、Astraで完了したことを確認した。不要注入は0回。

- 初回の有効な切替要求は、旧ターンを中断せず`MODEL_SWITCH.md`を拒否理由として元モデルへ返す
- 同じthread・同じ文書・同じ切替要求の再試行は許可し、turnIdには依存しない
- 同じthread・文書でも切替要求が変われば再注入する
- 別threadと文書変更は再注入する
- model・effortが同じで追加設定のない要求は注入しない
- 同一model・effortでも追加設定が変わる場合は注入する
- 入力不正・文書欠落・記録不能は切替を許可しない

Batonの`PreModelSwitch`は標準出力を使用しないため、配布hookは手順を標準エラーへ出し`exit 2`で返す。通常のCodex hook JSONとは共用しない。

Baton経由かどうかを通常のCodex `PreToolUse`から正確に識別できないため、`MODEL_SWITCH.md`の直接読込はそこで拒否しない。Baton対応時は`MODEL_SELECTION.md`の条件に従って事前読込を省略し、Baton非対応時は従来どおり切替前に読む。

実モデルprobeは`node tests/probe_baton_pre_model_switch_runtime.mjs /Users/kaikojima/Desktop/develop/baton`で再実行する。外部モデルを呼ぶため通常suiteには含めず、events・rollout・集計を新しい一時directoryへ保存する。

任意probeのRPC無応答時に内部timeout後も待機が残る`medium`指摘は、本番hook・通常suite・モデル実行へ影響せず外側から停止できるため、修正対象外とした。

モデル選択の遅延注入に対する`unwind`参照の`medium`指摘は、`unwind`がpolish後の明示工程でありpreflight前のdifficultyを代替する経路ではないため、対象外として却下した。修正工程での再評価参照は維持する。
