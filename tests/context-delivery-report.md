# Context配信検証（2026-09-11）

行数ではなく、配線から出た文書・拒否理由のUTF-8 bytes、配信回数、宛先、再試行時の重複を測定した。全体suite内の再現テストと、実モデルを呼ぶCLI probeは別の証拠として扱う。

## 再現テスト

`test_context_delivery.py`はClaude/Codex両配布の全matcherを通す。併設環境・nested cwd・再試行・契約欠落・glob・Git参照も含む。

| 操作 | 文書注入 |
|---|---|
| 通常コード編集・文書修正・調査 | 0 |
| 明示 `tdd --from-doc` のprompt受信 | 0（skillで扱う） |
| difficulty起動前 | 共通手順を親へ1回、操作をdeny |
| difficulty開始 | 評価契約を子へ1回 |
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
- 同じthread・同じ文書の再試行は許可し、turnIdには依存しない
- 別threadと文書変更は再注入する
- model・effortが同じで追加設定のない要求は注入しない
- 同一model・effortでも追加設定が変わる場合は注入する
- 入力不正・文書欠落・記録不能は切替を許可しない

Batonの`PreModelSwitch`は標準出力を使用しないため、配布hookは手順を標準エラーへ出し`exit 2`で返す。通常のCodex hook JSONとは共用しない。

Baton経由かどうかを通常のCodex `PreToolUse`から正確に識別できないため、`MODEL_SWITCH.md`の直接読込はそこで拒否しない。Baton対応時は`MODEL_SELECTION.md`の条件に従って事前読込を省略し、Baton非対応時は従来どおり切替前に読む。

実モデルprobeは`node tests/probe_baton_pre_model_switch_runtime.mjs /Users/kaikojima/Desktop/develop/baton`で再実行する。外部モデルを呼ぶため通常suiteには含めず、events・rollout・集計を新しい一時directoryへ保存する。
