## HTTP Request
- サンドボックス外で行うこと

## メインモデルの選択

- Codexのメインエージェントで `switch_main_model` が利用可能な場合だけ、作業前にモデル選択基準を読み、作業の性質が変わったときも適用する。配布元では `skills/MODEL_SELECTION.md`、配置先では `[skills_root]/MODEL_SELECTION.md` を読む。
- ツールが利用できない環境と子エージェントには、この切り替え操作を要求しない。
