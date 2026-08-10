#!/bin/bash
# rebase スキルの決定的実行スクリプト。
# 「[<エージェント名>]: {ファイル名}/{変更内容}」の 1 ファイル = 1 コミット履歴を、未 push 範囲だけ
# 機能単位の squash 履歴へ組み替える。履歴書き換えの唯一の公認経路
# （生の rebase / filter-branch / force push は deny-history.sh が deny する）。
#
# 使い方:
#   rebase.sh --check [--base <ref>]  # 前提検査と対象範囲の報告（履歴を変更しない）
#   rebase.sh [--base <ref>] --group <subject> <sha[,sha...]> [--group ...]
#                                      # group 指定に従いリプレイ実行
#
# 安全設計（verify-then-swap）:
#   temp worktree で base から cherry-pick -n によるリプレイを完走させ、
#   「plan が対象範囲を exactly-once で消費」「squash 後の tree が元 HEAD と同一」の
#   二重検証に合格して初めて、本体ブランチを 1 回の reset --hard で切り替える。
#   検証前に本体ブランチと作業ツリーには一切触れないため、失敗時は temp worktree を
#   消すだけでよく、復元パスが存在しない。
# 失敗の扱い: 検査・リプレイ・検証のどこで落ちても ERROR を stderr へ出して exit 1
#   （成功したふりの禁止）。push は本スクリプトは行わない。
# backup ブランチ: swap（reset --hard）の間だけ ORIG へ名前を張る一時的な足場であり、
#   swap 成功後は削除する。成功時に残さないので、backup が残っていれば swap 失敗の証拠になる。
set -u

err() { echo "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

MODE="" BASE_ARG="" GROUP_COUNT=0
GROUP_SUBJECTS=()
GROUP_COMMITS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      [ -z "$MODE" ] || die "--check と --group は同時に指定できない"
      MODE=check
      ;;
    --base) shift; BASE_ARG="${1:?--base には ref が必要}" ;;
    --group)
      [ "$MODE" != check ] || die "--check と --group は同時に指定できない"
      MODE=run
      shift
      [ $# -gt 0 ] || die "--group には subject が必要"
      GROUP_SUBJECTS[$GROUP_COUNT]=$1
      shift
      [ $# -gt 0 ] || die "--group にはカンマ区切りの commit sha が必要"
      case "$1" in
        ""|,*|*,|*,,*) die "--group の commit sha リストが不正: $1" ;;
      esac
      GROUP_COMMITS[$GROUP_COUNT]=$1
      GROUP_COUNT=$((GROUP_COUNT + 1))
      ;;
    *) die "不明な引数: $1" ;;
  esac
  shift
done
[ -n "$MODE" ] || die "usage: rebase.sh --check [--base <ref>] | rebase.sh [--base <ref>] --group <subject> <sha[,sha...]> [--group ...]"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリ内で実行すること"
[ "$(git rev-parse --abbrev-ref HEAD)" != "HEAD" ] || die "detached HEAD では実行しない"

# 通常コミット hook と同じ配置済み契約を読む。subject の規則をこの実行器に複製しない。
REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_MESSAGE_CONTRACT="$REPO_ROOT/.[agent_name]/hooks/shell/commit-subject.sh"
[ -r "$COMMIT_MESSAGE_CONTRACT" ] || die "コミットsubject契約が無い: $COMMIT_MESSAGE_CONTRACT"
. "$COMMIT_MESSAGE_CONTRACT"

# clean tree 前提（untracked は無害なので許容）
git status --porcelain | grep -qv '^??' && \
  die "作業ツリーが dirty。コミットするか退避してから実行すること"

ORIG=$(git rev-parse HEAD)

# base の決定: --base 指定 > @{upstream}。upstream なしで --base も無ければ動かない
if [ -n "$BASE_ARG" ]; then
  BASE=$(git rev-parse --verify "${BASE_ARG}^{commit}" 2>/dev/null) || die "base を解決できない: $BASE_ARG"
else
  BASE=$(git rev-parse --verify '@{upstream}' 2>/dev/null) || die "upstream が無い。--base <ref> で明示すること"
fi
git merge-base --is-ancestor "$BASE" "$ORIG" || die "base($BASE) が HEAD の祖先でない"

[ -z "$(git rev-list --merges "$BASE..$ORIG")" ] || die "範囲に merge コミットがある。本スキルの対象外"

# 「未 push」の判定は upstream 比較では不十分（PR ブランチ等へ push 済みでも @{u}..HEAD に残る）。
# 範囲の全コミットが全リモート追跡 ref から不可視であることを要求する
TOTAL=$(git rev-list --count "$BASE..$ORIG")
INVISIBLE=$(git rev-list --count "$BASE..$ORIG" --not --remotes)
[ "$TOTAL" -eq "$INVISIBLE" ] || \
  die "範囲内にリモートへ push 済みのコミットが $((TOTAL - INVISIBLE)) 件ある。共有履歴は書き換えない"

# 契約外のコミットは境界: 最新の契約外コミットより古い側は対象から外す
EFFECTIVE_BASE=$BASE
while IFS=$'\t' read -r sha subject; do
  commit_message_subject_is_valid "$subject" || EFFECTIVE_BASE=$sha
done < <(git log --reverse --format='%H%x09%s' "$BASE..$ORIG")

COUNT=$(git rev-list --count "$EFFECTIVE_BASE..$ORIG")

if [ "$MODE" = check ]; then
  echo "BASE $EFFECTIVE_BASE"
  echo "HEAD $ORIG"
  echo "COMMITS $COUNT"
  echo "SUBJECT_FORMAT $(commit_message_format)"
  if [ "$COUNT" -lt 2 ]; then
    echo "NOTHING-TO-DO: squash 対象が 2 コミット未満"
    exit 0
  fi
  # 分類の材料: 対象コミット（古い順）と、それぞれの変更ファイル
  while IFS= read -r sha; do
    printf '%s\t%s\n' "$(git log -1 --format=%h "$sha")" "$(git log -1 --format=%s "$sha")"
    git show --name-only --format= "$sha" | sed 's/^/\t/'
  done < <(git rev-list --reverse "$EFFECTIVE_BASE..$ORIG")
  exit 0
fi

# ---- run モード ----
[ "$COUNT" -ge 2 ] || die "squash 対象が 2 コミット未満。やることがない"
NGROUPS=$GROUP_COUNT
[ "$NGROUPS" -ge 1 ] || die "group が空"

# 契約検証は共有実装で行う。通常コミット hook はスクリプト内部の commit を
# 見られない(コマンド文字列検査のため)が、subject 規則は同じままにする。
gi=0
while [ "$gi" -lt "$NGROUPS" ]; do
  subj=${GROUP_SUBJECTS[$gi]}
  commit_message_subject_is_valid "$subj" || \
    die "subject が契約形式でない: $subj (期待: $(commit_message_format))"
  commit_message_has_forbidden_ai_signature "$subj" && \
    die "subject に AI 署名が含まれる: $subj"
  gi=$((gi + 1))
done

# exactly-once 検証: group のコミット集合 = 対象範囲、重複も欠落も許さない
GROUP_SHAS=""
gi=0
while [ "$gi" -lt "$NGROUPS" ]; do
  COMMIT_LIST=${GROUP_COMMITS[$gi]}
  OLD_IFS=$IFS
  IFS=','
  for s in $COMMIT_LIST; do
    full=$(git rev-parse --verify "${s}^{commit}" 2>/dev/null) || die "group に解決できない sha がある: $s"
    GROUP_SHAS="$GROUP_SHAS$full
"
  done
  IFS=$OLD_IFS
  gi=$((gi + 1))
done
if [ "$(printf '%s' "$GROUP_SHAS" | sort)" != "$(git rev-list "$EFFECTIVE_BASE..$ORIG" | sort)" ]; then
  die "group のコミット集合が対象範囲と exactly-once で一致しない(欠落・重複・範囲外のいずれか)"
fi

BACKUP="backup/rebase-$(git rev-parse --short=7 "$ORIG")"
git show-ref --verify --quiet "refs/heads/$BACKUP" && \
  die "backup ブランチが既に存在する: ${BACKUP}。成功時は自動削除されるので、これは前回の swap が失敗した証拠。確認と削除は人間の仕事"

WT=$(mktemp -d "${TMPDIR:-/tmp}/rebase.XXXXXX") || die "temp dir を作れない"
cleanup() {
  git worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT"
}
git worktree add --detach "$WT" "$EFFECTIVE_BASE" >/dev/null 2>&1 || { rm -rf "$WT"; die "temp worktree を作れない"; }

gi=0
while [ "$gi" -lt "$NGROUPS" ]; do
  SUBJECT=${GROUP_SUBJECTS[$gi]}

  # グループ内の指定順は信用せず、元履歴の順序へ再ソートする
  GROUP_RESOLVED=""
  COMMIT_LIST=${GROUP_COMMITS[$gi]}
  OLD_IFS=$IFS
  IFS=','
  for s in $COMMIT_LIST; do
    full=$(git rev-parse --verify "${s}^{commit}" 2>/dev/null) || { cleanup; die "group に解決できない sha がある: $s"; }
    GROUP_RESOLVED="$GROUP_RESOLVED$full
"
  done
  IFS=$OLD_IFS
  [ -n "$GROUP_RESOLVED" ] || { cleanup; die "group $((gi + 1)) にコミットが無い: $SUBJECT"; }
  GROUP_ORDERED=$(git rev-list --reverse "$EFFECTIVE_BASE..$ORIG" | grep -Fx -f <(printf '%s\n' "$GROUP_RESOLVED"))

  for sha in $GROUP_ORDERED; do
    if ! git -C "$WT" cherry-pick --no-commit "$sha" >/dev/null 2>&1; then
      short=$(git log -1 --format=%h "$sha")
      cleanup
      die "コンフリクト: group $((gi + 1))「${SUBJECT}」の $short を並べ替えて適用できない。グループを併合するか、元履歴で連続する run だけを squash する縮退 group に組み直すこと(本体ブランチは無傷)"
    fi
  done

  # 相殺で空になったグループは分類の誤り。--allow-empty で誤魔化さない
  if git -C "$WT" diff --cached --quiet; then
    cleanup
    die "group $((gi + 1))「${SUBJECT}」は変更が相殺されて空。revert とその対象は同一グループに入れないこと"
  fi

  # commit message は group の subject 1 行のみ(body は付けない)。
  # --no-verify: 内容は元コミット時点で hook 通過済みの内容保存変換であり、
  # 配布先の commit hook(フォーマッタ等)が tree を書き換えると検証が壊れるため
  git -C "$WT" commit --quiet --no-verify -m "$SUBJECT" || { cleanup; die "commit に失敗: group $((gi + 1))「${SUBJECT}」"; }

  gi=$((gi + 1))
done

NEW_TIP=$(git -C "$WT" rev-parse HEAD)

# 二重検証: これに合格するまで本体ブランチには触れない
git diff --quiet "$ORIG" "$NEW_TIP" || \
  { cleanup; die "検証失敗: squash 後の tree が元 HEAD と一致しない。リプレイのどこかで内容が変わった"; }
NEWCOUNT=$(git rev-list --count "$EFFECTIVE_BASE..$NEW_TIP")
[ "$NEWCOUNT" -eq "$NGROUPS" ] || \
  { cleanup; die "検証失敗: 生成コミット数($NEWCOUNT) が groups($NGROUPS) と一致しない"; }

# verify-then-swap: backup を切ってから、本体を 1 回だけ動かす。
# tree は検証済みで元 HEAD と同一なので、この reset --hard は作業ファイルを 1 byte も変えない
git branch "$BACKUP" "$ORIG" || { cleanup; die "backup ブランチを作れない: $BACKUP"; }
if ! git reset --hard "$NEW_TIP" >/dev/null 2>&1; then
  cleanup
  die "swap(reset --hard) に失敗。ブランチは $BACKUP と reflog から復旧できる"
fi
# swap 成功。backup はここまでの足場であり、成果物ではないので削除する。
# 削除に失敗しても swap 自体は成功しているので、警告に留めて成功扱いにする
git branch -D "$BACKUP" >/dev/null 2>&1 || \
  echo "WARN: backup ブランチを削除できなかった: $BACKUP (手動で削除すること)" >&2
cleanup

echo "OK: $COUNT commits -> $NGROUPS commits"
echo "元 HEAD: $ORIG (backup ブランチは削除済み。reflog から辿れる)"
echo "検証: tree 一致(元 HEAD と diff 空) / 全コミット exactly-once 消費"
git log --reverse --format='%h%x09%s' "$EFFECTIVE_BASE..HEAD"
