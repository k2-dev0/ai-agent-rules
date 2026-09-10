# 設計書モード

`$tdd --from-doc`だけが読む。`.[agent_name]/prompt/.prompt.md`の先頭にある未完了の`branch-<機能名>-prompt.md`を要求根拠、機能名をscope名とする。参照先がない、または未完了項目がなければ変更せず報告する。

対象は設計書1枚・1 branch・1 PRに限定し、他の設計書や次の項目へ進まない。

実装・検証・commit後、次の出力にある実変更pathをまとめて[polish](../polish/PROCEDURE.md)へ渡し、verifiedで実行する。fileごとに分割しない。

```bash
bash [skills_root]/polish/capture-scope.sh list-changed <機能名>
```

polish、index残件数、通常の完了報告を示し、完了markを付けるか確認する。ユーザーが付けると回答した場合だけ次を単独実行する。

```bash
bash [skills_root]/tdd/mark-prompt-done.sh <機能名>
```
