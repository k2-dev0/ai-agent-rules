# 子の共通制約

shellは読み取り・検索・hash確認だけに使う。test・formatter・lint・build・install、外部通信、編集・Git変更、モデル変更、再委任、承認要求は行わない。各roleの調査範囲を守り、親の会話・ログ・過去のレビュー結果を取得しない。
