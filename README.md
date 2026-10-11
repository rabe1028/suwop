# Suwop

Apple Photos と Immich の写真を一つの一覧で確認し、原本の保存先を確認・コピー・移動する iPhone / iPad / Mac 向け PoC です。

共通コアは Rust + Crux 0.20.0、UI は SwiftUI です。Swift に残すのは表示、PhotoKit、Keychain、URLSession、ファイルの入出力です。写真の同一性判定、保存状態、コピー／移動の進行、削除可否、Immich API の構築は Rust が担当します。

日・月・年のグリッド、表示密度、名前・撮影日の検索、メディアと保存先の絞り込み、複数選択、お気に入りの整理、静止画の全画面閲覧・前後移動・ズームを備えています。お気に入りは、統合された写真の Apple Photos / Immich の両方へ反映します。日付検索は端末のタイムゾーンで照合します。保存先ごとのアルバムの作成・名前変更・所属追加と解除・アルバム削除に対応し、写真の原本を残します。単独・複数選択の原本ファイルをシステム共有画面へ渡せます。位置情報などのメタデータも含み、Live Photo の静止画と動画、RAW と JPEG はそれぞれの原本ファイルとして渡します。動画・Live Photo の原本再生にも対応します。再生用ファイルを検証し、再生画面を閉じるまで保持します。写真編集、編集後の再生・共有とメタデータ除去は今後の実装対象です。実装と実機での検証状況は [Photos 操作の到達条件](docs/photos-parity.md) を参照してください。

## 起動と開発

必要: macOS、Xcode、Homebrew、Python 3.11 以上、rustup。Docker 統合テストには Docker が必要です。

```sh
make setup             # 固定バージョンの Lint ツールと Git hooks
make apple-core        # Rust の device / Simulator / Mac XCFramework
xcodegen generate
open Suwop.xcodeproj
```

Xcode で `SuwopiOS` または `SuwopmacOS` を選びます。実機では Signing の Team を設定してください。`make` は通常の Xcode インストールを選択します。別の場所にある場合は `DEVELOPER_DIR` を指定します。

1. Immich の URL と API キーを設定します。API キーは Keychain に保存します。
2. 一覧を更新し、Apple Photos へのアクセスを許可します。
3. 「未照合の原本を照合」を実行します。iCloud 上の原本をダウンロードする場合があります。
4. 写真詳細からコピー、または移動準備を実行します。
5. 移動は「転送履歴・移動確認」から明示的に完了します。

HTTPS が既定です。HTTP は設定で明示的に許可した場合だけ使用します。

## 品質チェック

```sh
make format            # Rust / Swift / Python の整形
make check             # 厳格な Lint、生成物差分、Rust と実 FFI のテスト
make apple-build       # universal Rust library、iOS Simulator / Mac のビルド
make integration       # 分離した Docker Immich v3.2.4 に対する実通信テスト
```

Rust 1.95.0、SwiftLint 0.65.1、SwiftFormat 0.63.1、Ruff 0.17.0、ShellCheck 0.11.0、actionlint 1.7.12 を固定します。Clippy の all / pedantic と警告をエラー扱いにし、Swift 6 の厳格な並行性チェックとコンパイラ警告のエラー化も有効です。Swift の生成 DTO は Rust のスキーマから再生成し、CI で差分を検出します。Git の pre-commit は Lint、pre-push はテストを実行し、既存の hooks は保存します。core.hooksPath の委譲を確認できる場合は連結し、不明な独自設定では上書きせず停止します。

Linux では `make setup` と `make check` で Rust／スクリプトを確認できます。Apple ビルドと Swift の FFI テストは macOS で行います。

Docker テストは `suwop-rust-test` という専用プロジェクトと localhost:2289 を使い、終了時にそのコンテナと volume を削除します。実際のアップロード、位置情報・お気に入りの反映、一覧、原本ダウンロード、スタック、XMP sidecar、ゴミ箱への移動を確認します。調査用に残す場合は `KEEP_IMMICH_TEST_ENV=1 make integration` を使います。プロジェクト名とポートは `IMMICH_TEST_PROJECT` / `IMMICH_TEST_PORT` で変更できます。

## コピーと移動

「両方」「Apple のみ」「Immich のみ」「一部だけ両方」「未照合」を区別します。RAW + JPEG は別原本として数え、JPEG だけの一致を完全保存とは判定しません。

移動はコピー、転送先の原本検証、別画面での確認、両側の再検証、元のゴミ箱への移動、という順序です。削除前には原本を読み直し、SHA-256 とバイト長、revision、位置情報を確認します。コピーの履歴を後から移動に使うことはできません。旧形式の履歴はコピーとして移行します。

Live Photo、編集・補助データ付き、バースト、External Library、XMP sidecar、独立した写真の同一バイト列重複などはコピーのみです。保存種別や sidecar が未確認の場合も削除しません。移動準備中の位置情報は Immich に反映し、転送先で一致を確認できない場合は元を残します。完全削除 API は使用しません。

削除結果が不明な場合は `deletionUncertain` として残し、自動で再試行しません。Apple Photos の削除は、iCloud 写真が有効なら他の端末にも同期されます。

詳しい境界は [設計](docs/architecture.md)、残る検証は [検証](docs/verification.md) を参照してください。
