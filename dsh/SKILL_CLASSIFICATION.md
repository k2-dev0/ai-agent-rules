# 配布skillの分類

`skills/` 配下の各directoryを、DSHでどう扱うかの正本。`dsh/test/skill-classification.test.js`がこのfileと実際のfrontmatterを照合する。

## 分類

| 対象 | 分類 | DSHでの扱い |
|---|---|---|
| `cowlick` | DSHでも共用可（明示起動のみ） | catalogへ出す。model invocationは無効 |
| `dictionary` | DSHでも共用可 | catalogへ出す。model invocation可 |
| `e2e` | DSHでも共用可（明示起動のみ） | catalogへ出す。model invocationは無効 |
| `meeting` | DSHでも共用可（明示起動のみ） | catalogへ出す。model invocationは無効 |
| `polish` | DSHでも共用可（明示起動のみ） | catalogへ出す。model invocationは無効 |
| `ponytail` | DSHでも共用可（明示起動のみ） | catalogへ出す。model invocationは無効 |
| `preflight` | DSHでも共用可（model専用） | catalogへ出す。user invocationは無効 |
| `rebase` | DSHでも共用可（明示起動のみ） | catalogへ出す。model invocationは無効 |
| `tdd` | DSHでも共用可 | catalogへ出す。model invocation可 |
| `unwind` | DSHでも共用可（明示起動のみ） | catalogへ出す。model invocationは無効 |
| `bootstrap` | Codex／Claude legacy専用 | catalogへ出さない。DSHには配置手順が無い |

`model invocationは無効`は`disable-model-invocation: true`を意味する。DSH mainは本文を自分でloadしないが、人間が明示的に起動すれば読める。routing記述だけをDSH向けに分離したskillは現時点で無い。分離が必要になった時点でこの表へ行を足す。

## 配布元の共通規約（skillではない）

`skills/`直下の次のfileはCodex／Claude／旧DeepSeek worker向けの共通規約であり、skill bundleではない。DSHのcatalogへ出さない。

`CHILD_RULES.md`、`CODE_REVIEW_CONTRACT.md`、`DEEPSEEK_WORKFLOW.md`、`DIFFICULTY_CONTRACT.md`、`FIX_FLOW.md`、`IMPLEMENTATION_RULES.md`、`INDEPENDENT_REVIEW.md`、`MODEL_SELECTION.md`、`MODEL_SWITCH.md`、`REVIEW_SEVERITY.md`、`SUBAGENT_RULES.md`、`WORKFLOW_ROUTING.md`

これらはDSH mainの自動review・自動model切替の根拠にしない。DSHへ効く指示は`AGENTS.dsh.md`（`dsh/lib/dsh-instructions.js`の`DSH_INSTRUCTIONS`としてsystem prompt sectionへ常時注入）だけ。

## DSHで無効化すべきもの

- `bootstrap`：配布先のplaceholderを解決して自己削除するlegacy導入手順。DSHのprofile installは`dsh plugin add`が担うため、DSH向けの等価手順は作らない。
- 上記の共通規約12 file：Codex／Claude runtimeのrouting規約であり、DSH mainの責務分担（`dsh/README.md`の「DSH mainの責務」）と競合する。
