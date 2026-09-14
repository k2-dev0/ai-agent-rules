#!/bin/bash
# PreToolUse(Bash) hook: Git のコミット操作をリポジトリ共通の契約に適合する形だけ通す。
# 契約: 1 ファイル = 1 コミット。コミットsubjectの対象名・日本語要件は
#       commit-subject.sh を唯一の実装として使う。
#       author は常にユーザー本人の git config identity（AI を author・co-author に混ぜない）。
# 本 hook は deny 専任。適合するコミットの自動化は settings の allow(Bash(git commit:*)) が担う。
# 例外(squash): 未 push 範囲のコミット整理は rebase スキルの決定的スクリプトのみが行い、
#       squash 実行器も同じ契約実装を source して subject を検証する。
#       生の履歴書き換えコマンドの deny は git-policy.py が担う。
# 出力汚染の根絶: 決定 hook は stdout の決定JSON 以外を外へ出さない契約。stderr を捨てる。
exec 2>/dev/null
. "$(dirname "$0")/hook-io.sh"
. "$(dirname "$0")/commit-subject.sh"
[ "$(hook_tool_name)" = "Bash" ] || exit 0
CMD=$(hook_command)
[ -z "$CMD" ] && exit 0

EXPECTED_STAGED_FILE_COUNT=1

# フラグ検査はクォート内(コミットメッセージ本文)を除去してから行う。
# メッセージ内の文字列(例:「-a オプションの説明」)をフラグと誤認しないため
MASKED=$(echo "$CMD" | sed 's/"[^"]*"//g' | sed "s/'[^']*'//g")

# rules / settings の禁止設定が欠けても共有履歴を変更できないよう、通常形も hook で拒否する。
echo "$MASKED" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]|$)' && \
  hook_deny "git push は禁止です。変更内容を確認したユーザー本人が実行してください。"
echo "$MASKED" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+cherry-pick([[:space:]]|$)' && \
  hook_deny "git cherry-pick は禁止です。履歴の取り込みはユーザー本人が実行してください。"

if echo "$MASKED" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit'; then
  # AI をコミット identity に混ぜる要素は禁止。
  commit_message_has_forbidden_ai_signature "$CMD" && \
    hook_deny "コミットへの AI 署名(Co-Authored-By / Generated with)は禁止です。author はユーザー本人の git config identity のままにしてください。"
  echo "$MASKED" | grep -qE -- '--author' && \
    hook_deny "--author の指定は禁止です。git config の identity(ユーザー本人)でコミットしてください。"
  echo "$MASKED" | grep -qE -- '--amend' && \
    hook_deny "--amend は履歴書き換えのため禁止です。修正は新しいコミットとして積んでください。"
  # 1 ファイル = 1 コミット: 変更全部を巻き込む一括コミットは禁止
  echo "$MASKED" | grep -qE 'git[[:space:]]+commit[^;&|]*[[:space:]](-a[m]?|--all)([[:space:]]|$)' && \
    hook_deny "-a / --all でのコミットは禁止です。1 ファイル = 1 コミットの契約に従い、対象ファイルだけを git add してからコミットしてください。"
  # commit 直前の index を正として検査し、別コマンドで複数 stage 済みの状態も拒否する。
  STAGED_FILES=$(git --no-pager --no-optional-locks -c core.fsmonitor=false diff --no-ext-diff --no-textconv --cached --name-only)
  STAGED_FILE_COUNT=$(printf '%s\n' "$STAGED_FILES" | awk 'NF { count++ } END { print count + 0 }')
  [ "$STAGED_FILE_COUNT" -eq "$EXPECTED_STAGED_FILE_COUNT" ] || \
    hook_deny "コミット直前に stage 済みのファイルが $STAGED_FILE_COUNT 件あります。1 ファイル = 1 コミットの契約に従い、厳密に1件だけ stage してください。"

  STAGED_FILE=$(printf '%s\n' "$STAGED_FILES" | awk 'NF { print; exit }')
  STAGED_BASENAME=${STAGED_FILE##*/}
  COMMIT_MESSAGE=$(printf '%s\n' "$CMD" | sed -nE 's/.*(-m|--message)[[:space:]]+"([^"]*)".*/\2/p')
  [ -n "$COMMIT_MESSAGE" ] || \
    COMMIT_MESSAGE=$(printf '%s\n' "$CMD" | sed -nE "s/.*(-m|--message)[[:space:]]+'([^']*)'.*/\\2/p")
  [ -n "$COMMIT_MESSAGE" ] || \
    hook_deny "コミットメッセージを検証できません。-m または --message とクォートしたメッセージを指定してください。"

  commit_message_is_valid_for_scope "$STAGED_BASENAME" "$COMMIT_MESSAGE" || \
    hook_deny "コミットメッセージが契約に一致しません。stage 済みのファイル名を対象名にしてください。形式: $(commit_message_format)"
fi

# 一括ステージングも 1 ファイル = 1 コミットの契約違反
echo "$MASKED" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+add[[:space:]]+(-A|--all|\.)([[:space:]]|$)' && \
  hook_deny "git add -A / git add . は禁止です。1 ファイル = 1 コミットの契約に従い、対象ファイルを個別に指定してください。"

# ignore 規則の迂回は、追跡対象に限るコミット契約を破る。強制ステージングは許可しない。
echo "$MASKED" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+add([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+(-f|--force)([[:space:];&|]|$)' && \
  hook_deny "git add -f / git add --force は禁止です。必要なfileがignoreされている場合は追跡方針を確認してください。別名への置換や検証対象からの除外で回避してはいけません。"

exit 0
