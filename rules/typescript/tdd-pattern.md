# テスト編集

## 手順・実行

挙動を変える本体実装はRed → Green → Refactorで進める。文書・設定・書式・下記test除外は必要な検証だけを行う。

1. 正常・境界値・異常・副作用から、要求漏れ・回帰を検出するシナリオを日本語で書く。正常系を一律除外せず、同じ契約の重複を避ける。
2. ユーザーが確認・修正したシナリオでTDDを行う。変更時は再確認する。`tdd`／`errand`では`[skills_root]/SCENARIO_FLOW.md`に従う。
3. 既存のVitest／Jestとtest scriptを使う（`yarn test <path>`／`npm test -- <path>`）。runner直起動・`npx vitest`・`npx jest`は禁止。

## 配置・除外

- 集中配置・隣接配置は既存規約に合わせる。Redの相対path・commandをbriefへ渡す。testは追跡済みまたはignore規則に一致するローカルfileにする。
- `.jsx`／`.tsx` component・React hookの画面挙動は、必要に応じて既存integration／E2Eで検証する。隣接unit testを必須にしない。
- `schema.prisma`、`constants.ts`、`constants.js`、`constants/`配下は対応test/spec・Red／Greenの対象外。

## 粒度

- 1 test 1 assertionを原則とし、describeは2階層まで。
- 結合テストを優先し、API・DB処理はPrisma mockでなくテストDBを使う。
- 外部API関数はmockで呼び出し条件・異常系、複雑な分岐はunit testで境界値・全分岐を検証する。
- その他は結合テストで確認し、バグの回帰防止・原因分離が必要になった場合だけunit testを追加する。最初から網羅しない。
- テスト専用exportは禁止。非公開関数は公開API経由で検証する。
