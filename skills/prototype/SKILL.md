---
name: prototype
description: 上司/自分の OK が出るまでの「使い捨て前提」のプロトタイプを最速で作る。テストは書かず（禁止）、可逆領域は承認なしでぶん回す。保護パスは sandbox と hook で物理的に死守する。
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, AskUserQuestion
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: .[agent_name]/hooks/shell/prototype.sh
---

## 契約

使い捨ての「動くもの」を最速で作る。コード編集・新規作成・検索・buildは配置済み権限内で進めるが、削除・移動・上書き系shellは確認し、保護pathとworkspace外はsandbox / hookで拒否する。テスト作成・編集は`prototype.sh`がdenyし、動作確認は実行で行う。

テスト禁止は起動セッション全体に残るため、**1セッション=1プロトタイプ**とする。OK後に同じセッションで本実装へ移らない。

## mode

- 引数なし: 対話で検証したい要件を絞る
- `from-prompt`: `@.[agent_name]/prompt/.prompt.md`と全`branch-*-prompt.md`を読み、全設計書を一つのプロトタイプとして実装する。要約だけ報告し、再承認は求めない

`from-prompt`でindexがない、または未実装項目がなければ引数なしへ戻る。indexは読み取り専用で、`mark-prompt-done.sh`を呼ばない。設計書のテスト条件はこのmodeでは適用しない。

## 起動前検査

承認なし実装の前提として、次を確認し、一つでも欠ければ起動しない。

- Claude Code: `sandbox.enabled=true`、`failIfUnavailable=true`、`denyWrite`に少なくとも`.git`とproject固有保護pathがある
- Codex: `default_permissions=distributed`で保護対象がread以下、`.codex/hooks.json`が信頼済み

## 権限境界

| 操作 | 扱い |
|---|---|
| 本体codeの編集・新規作成 | workspace権限内で承認不要 |
| `*.test.*`の作成・編集 | hookでdeny |
| 読み取り・build等のshell | 配置済みallowまたはsandbox内だけ |
| `rm`、`mv`、`sed -i`等 | 都度確認 |
| `.git`、`.env`、lockfile等の保護path | sandboxとhookで拒否 |
| workspace外 | sandboxで拒否 |

## フロー

1. 起動前検査を通す
2. modeに従って要件を確定する
3. 最小の動く本体codeを実装する。テストは書かない
4. 実行して確認する
5. 一段落ごとに「修正を続ける / 終了」を一度に一つ尋ねる。継続なら3へ戻る

## 終了

ユーザーが終了を選んだ後はtoolを一切呼ばず、次だけを返す。

> `/exit`（またはCtrl+C）でこのセッションを終了してください。本実装は新しいセッションでtddへ。

終了後に調査・修正を再開しない。fileによるoff switchはprocessと寿命がずれて漏れるため作らない。OK後のcodeをそのまま本番化せず、新しいセッションのtddでテストと本実装を行う。
