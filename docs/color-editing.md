# 明るさ・色・フィルターの編集

Apple Photos の対応する静止画を「写真を編集」で開く。
露出、明るさ、コントラスト、彩度を調整し、モノクロ・ノアール・セピアを選択できる。
スライダーを離すとプレビューを更新する。切り抜き・回転・反転と同じ履歴で取り消し・やり直しができる。
「開始時に戻す」は編集開始時の見た目に戻す。写真の原本へ戻す操作は、情報画面の別の確認付き操作を使う。

Rust が整数の調整値、許容範囲、履歴、保存可否と Core Image に渡すパラメーターを管理する。
露出は -2.00〜2.00 EV、その他は -100〜100、0が未調整。
向きを補正した原本に切り抜き・回転・反転を適用し、露出→明るさ・コントラスト・彩度→フィルターの順で描画する。
Swift は Rust の計画に沿って Core Image と PhotoKit を実行する。

編集データのバージョンは2。以前のバージョン1の幾何編集は色調整なしとして読み込む。
バージョン1を名乗る色調整、未知のバージョン・フィルター・範囲外・不正な値は拒否する。
他アプリの既存編集を原本から再現できない場合は PhotoKit が提供する現在の見た目を編集の土台にする。
原本の構成・バイト列と日時・位置・お気に入りの保持、保存後の編集データ・サイズの読取を、従来の編集経路で確認する。
プレビュー・保存は同じ描画経路を使い、キャンセル時は native worker の終了を待ってから作業ファイルを片付ける。

現在の Apple 編集と同じく SDR・対応する色空間・1,600万画素以内が対象。
HDR・24/48MP・透過の保存・動画・Live Photo・Immichへの色編集の保存は残作業。
Core Image のフィルターを使用し、Apple Photos 専用フィルターとの画素一致は主張しない。

検証は Rust の履歴・旧データ互換、実 Rust ABI、Core Image の画素・Display P3・原本保持、
simslim VRT の通常・調整済み・大きな文字の編集画面、Apple target builds を分ける。
実 PhotoKit の保存→再起動→再編集→原本復元、実機・iCloudの結果は別途確認する。

参照: [Apple の写真編集ガイド](https://support.apple.com/guide/iphone/edit-photos-and-videos-iphb08064d57/26/ios/26)、
[Core Image の colorControls](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/colorcontrols())。
