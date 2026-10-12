# 軽量 VRT

```sh
make setup-vrt
make vrt
```

Apple Silicon Mac / Xcode 26.4.1 / iOS 26.4.1（23E254a）/ iPhone 17 Pro を固定する。
環境が一致しなければ比較を開始しない。`DEVELOPER_DIR` で Xcode を選べる。
Simulator runtime は Xcode の Settings → Components から追加する。

チェックアウト専用の Simulator を一台だけ作成・再利用し、simslim 0.12.2 の
コミット済みプロファイルを適用・検証する。既存の利用者の Simulator は変更しない。
並列テストのクローンを作らず、終了時に専用 Simulator を shutdown してメモリを解放する。
Rust は arm64 Simulator 一種類だけをビルドする。Cargo と Xcode の成果物は再利用する。
通常の `make check` は Simulator を起動せず、VRT は別の必須 CI ジョブで実行する。

専用のテストホストに製品の SwiftUI 画面をそのままコンパイルする。
固定された保存状態を実際の Rust ABI に渡して ViewModel を作り、テスト用の幾何画像を表示する。
実写真・PhotoKit・Keychain・ネットワークは使用しない。テスト専用のモデル初期化は
`SUWOP_VRT` が有効なホストにのみ含まれ、製品アプリには含まれない。

14 枚を、日本語・UTC・402 × 874 pt / 3x・アニメーション無効で描画する。
空の一覧（明暗・大きな文字）、写真一覧（明暗）、日別選択、写真ビューア、保存先情報、
アルバム、接続設定、転送画面と、最近削除した項目の空・キャッシュ・結果不明の画面を対象にする。
双方の PNG を sRGB RGBA に正規化し、全画素を比較する。
同一画面の再描画で確認したネイティブぼかしの量子化差として RGB 各成分 2/255 までを許容する。
不一致画素の割合による猶予はなく、この差を超える一画素、透明度、サイズの変更は失敗する。
基準画像がない場合や画面数が欠けた場合も失敗する。

結果は `DerivedData/VRTArtifacts/<日時>-<実行ID>/` に保存される。
`*-actual.png`、不一致時の `*-expected.png` / `*-diff.png`、XCTest の xcresult、
simslim の状態・メモリ計測、各工程の時間を含む `report.json` を確認する。
CI は成功・失敗どちらも成果物を 14 日間保存する。

意図的な UI 変更後は、まず差分を確認する。基準画像の更新は明示的に行う。

```sh
make vrt-record
# VRT/Baselines/*.png を見て、意図した表示か確認する
make vrt
git diff -- VRT/Baselines
```

CI 内の記録は拒否する。比較処理は基準画像を変更しない。
OS / Xcode 更新時も固定環境の設定と基準画像を同じ変更でレビューする。
この VRT は表示の退行を検出する。PhotoKit、実機、iCloud、共有先アプリでの動作確認は別途必要。
