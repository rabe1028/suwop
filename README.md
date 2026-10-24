# Suwop

Apple Photos・Immich・日本のAmazon Photosの写真を一つの一覧で確認し、原本の保存先を確認・コピーする iPhone / iPad / Mac 向け PoC です。Apple PhotosとImmichの間では、原本を検証してから移動できます。

共通コアは Rust + Crux 0.20.0、UI は SwiftUI です。Swift に残すのは表示、PhotoKit、Keychain、URLSession、ファイルの入出力です。写真の同一性判定、保存状態、コピー／移動の進行、削除可否、Immich・Amazon Photos API の構築は Rust が担当します。

日・月・年のグリッド、表示密度、名前・撮影日の検索、メディアと保存先の絞り込み、複数選択、お気に入りの整理、静止画の全画面閲覧・前後移動・ズームを備えています。お気に入りは、統合された写真の Apple Photos / Immich / Amazon Photos へ反映します。日付検索は端末のタイムゾーンで照合します。Apple PhotosとImmichでは、アルバムの作成・名前変更・所属追加と解除・アルバム削除に対応し、写真の原本を残します。

[Amazon Photos（日本）](docs/amazon-photos.md)は、アプリ内ブラウザでログインし、Cookieを端末のKeychainに保存する非公式API連携です。一覧・プレビュー・原本取得・双方向コピー・お気に入りに対応します。コピー後は原本を再取得してSHA-256を照合します。受け付けない形式やLive Photoの組は変換せず停止し、理由とApple Photos / Immichへの保存を案内します。Amazonを含む移動・削除、Amazonのアルバム編集・メタデータ変更は未対応です。

同じ原本でも保存先によって編集結果が異なる場合は、全画面から表示元を選べます。グリッドと撮影日時も選んだコピーに合わせます。選択先にアクセスできなくなった場合は再選択を求めます。選択は現在の起動中に保持し、再起動時は既定の表示元に戻ります。

単独・複数選択の原本ファイルをシステム共有画面へ渡せます。位置情報などのメタデータも含み、Live Photo の静止画と動画、RAW と JPEG はそれぞれの原本ファイルとして渡します。全画面では、選んだ表示元の現在の静止画を共有できます。Apple Photosの現在の画像とImmichの未編集原本は、取得したバイト列のまま共有します。Immich 3.xの編集後は、検証した原本と最新の切り抜き・90度回転・反転の系列からPNGを生成し、撮影日時・位置と色空間・透過を保持します。1,600万画素以内のSDR画像に対応し、編集中の変更・非対応の系列・原本や出力の不一致では共有を止めます。原本ファイルと編集系列は変更しません。現在の動画／Live Photoと複数選択の共有は継続作業です。動画・Live Photo の原本再生にも対応します。再生用ファイルを検証し、再生画面を閉じるまで保持します。情報画面から保存先を選んで撮影日時・緯度と経度を変更できます。Apple Photos の位置情報削除にも対応します。

Apple の静止画には切り抜き、90度回転、上下・左右の反転、取り消し・やり直しと保存、確認後の原本への復元を実装しています。初期の編集上限は1,600万画素で、画像の展開前に判定します。選んだ保存先の原本を保持し、現在の編集を開始状態として扱います。復元と現在の静止画共有には、この画素展開の上限を適用しません。高解像度・HDR・透過・動画・Live Photo と Immich の写真編集は継続作業です。Apple静止画の露出・明るさ・コントラスト・彩度と3フィルター、項目を選ぶ[編集のコピー／ペースト](docs/edit-copy-paste.md)も実装しています。専用Simulatorの生成JPEGでは、[PhotoKitの実保存・起動し直した後の読取・復元](docs/native-photokit.md)を検証しています。実機・iCloud・他アプリの既存編集との往復は残っています。ライブラリの変更後も原本ファイルの EXIF は保持するため、原本共有の位置情報除去と編集後の動画／Live再生・共有も今後の実装対象です。実装と実機での検証状況は [Photos 操作の到達条件](docs/photos-parity.md) を参照してください。

## 起動と開発

必要: macOS、Xcode、[mise](https://mise.jdx.dev/)、rustup。Docker 統合テストには Docker が必要です。

```sh
make setup             # mise.lock の固定ツールと Git hooks
make apple-core        # Rust の device / Simulator / Mac XCFramework
xcodegen generate
open Suwop.xcodeproj
```

Xcode で `SuwopiOS` または `SuwopmacOS` を選びます。実機では Signing の Team を設定してください。`make` は通常の Xcode インストールを選択します。別の場所にある場合は `DEVELOPER_DIR` を指定します。

1. 接続設定で、Immich の URL と API キーを設定するか、日本のAmazonアカウントでログインします。API キーとCookieは Keychain に保存します。
2. 一覧を更新します。Apple Photosも利用する場合は、写真へのアクセスを許可します。
3. 「未照合の原本を照合」を実行します。iCloud 上の原本をダウンロードする場合があります。
4. 写真詳細からコピー、または移動準備を実行します。
5. 移動は「転送履歴・移動確認」から明示的に完了します。

HTTPS が既定です。HTTP は設定で明示的に許可した場合だけ使用します。

## 品質チェック

```sh
make format            # Rust / Swift / Python の整形
make check             # 厳格な Lint、生成物差分、Rust と実 FFI のテスト
make apple-build       # ARM64 Rust library、iOS Simulator / Mac のビルド
make integration       # 分離した Docker Immich v3.2.4 に対する実通信テスト
make setup-vrt         # mise.lock の simslim 0.12.2 を導入（make setup と同じ）
make vrt               # 一台の軽量 Simulator で SwiftUI 23 画面の画素差分を比較
make apple-native-test # 同じ専用 Simulator で実 PhotoKit の保存・再起動・復元を確認
```

空き容量が厳しい場合は `SUWOP_CLEAN_CHECK=1 make check` を使えます。Clippy・生成物確認・Rustテスト・Swift用ライブラリ生成の各段階を完了してから、不要になった Rust のビルドキャッシュだけを clean します。全チェックを実行し、Swift用の生成済みライブラリは保持します。通常実行ではキャッシュを保持します。

ツールは `mise.toml` で固定し、各プラットフォームの URL とチェックサムを `mise.lock` に記録します（uv、Ruff、ShellCheck、actionlint、cargo-nextest、SwiftLint、SwiftFormat、XcodeGen、simslim）。手動のダウンロードや Homebrew での導入はしません。Rust 1.95.0 は `rust-toolchain.toml` で固定します。Clippy の all / pedantic と警告をエラー扱いにし、Swift 6 の厳格な並行性チェックとコンパイラ警告のエラー化も有効です。Swift の生成 DTO は Rust のスキーマから再生成し、CI で差分を検出します。Git の pre-commit は Lint、pre-push はテストを実行し、既存の hooks は保存します。core.hooksPath の委譲を確認できる場合は連結し、不明な独自設定では上書きせず停止します。

Linux では `make setup` と `make check` で Rust／スクリプトを確認できます。Apple ビルドと Swift の FFI テストは macOS で行います。

VRT は Apple Silicon / Xcode 26.4.1 / iOS 26.4.1 を固定し、専用 Simulator とビルド成果物を再利用します。
実写真や通信を使わず、明暗・大きな文字も含めて表示を比較します。差分確認と明示的な基準画像更新は [VRT](docs/vrt.md) を参照してください。

Docker テストは `suwop-rust-test` という専用プロジェクトと localhost:2289 を使い、終了時にそのコンテナと volume を削除します。実際のアップロード、日時・タイムゾーン・位置情報・お気に入りの反映、一覧、原本ダウンロード、スタック、XMP sidecar、ゴミ箱への移動を確認します。調査用に残す場合は `KEEP_IMMICH_TEST_ENV=1 make integration` を使います。プロジェクト名とポートは `IMMICH_TEST_PROJECT` / `IMMICH_TEST_PORT` で変更できます。

## コピーと移動

「両方」「Apple のみ」「Immich のみ」「一部だけ両方」「未照合」に加え、Amazonと複数保存先の状態を表示します。未照合の原本がある場合は、別の保存先に原本がないとは断定しません。RAW + JPEG は別原本として数え、JPEG だけの一致を完全保存とは判定しません。

移動はコピー、転送先の原本検証、別画面での確認、両側の再検証、元のゴミ箱への移動、という順序です。削除前には原本を読み直し、SHA-256 とバイト長、revision、位置情報を確認します。コピーの履歴を後から移動に使うことはできません。旧形式の履歴はコピーとして移行します。

Immich に新しく作成したコピーには、ライブラリ上の撮影日時を反映します。日時の抽出を待って既存の値と比較し、一致する日時の更新は省きます。必要のない XMP sidecar を日時変更だけで作りません。原本ファイルの EXIF と異なる日時を Apple Photos で設定した場合も、既知の絶対日時を UTC で渡します。原本のバイト列は変更しません。重複として返された既存の Immich 写真には、日時やお気に入りを上書きしません。撮影日時が不明な場合は EXIF 日時を変更せず、不正な日時はアップロード前に拒否します。

このコピー処理では Apple ライブラリの元のタイムゾーンを取得できないため、Immich側のタイムゾーン別の時計表示の再現は保証しません。日時の照合許容差は1ミリ秒です。原本ファイル内の元の EXIF 日時・タイムゾーンは保持します。

Live Photo、編集・補助データ付き、バースト、External Library、XMP sidecar、独立した写真の同一バイト列重複などはコピーのみです。保存種別や sidecar が未確認の場合も削除しません。移動準備中の位置情報は Immich に反映し、転送先で一致を確認できない場合は元を残します。完全削除 API は使用しません。

削除結果が不明な場合は `deletionUncertain` として残し、自動で再試行しません。Apple Photos の削除は、iCloud 写真が有効なら他の端末にも同期されます。

詳しい境界は [設計](docs/architecture.md)、残る検証は [検証](docs/verification.md) を参照してください。

Immich 3.2以降では、保存先情報または複数選択から通常のゴミ箱へ移し、コレクションの「最近削除した項目」から復元できます。
確認前後の検証と送信前の記録保存をRustで行い、通信断後の書き込みは再送しません。[削除・復元の手順と境界](docs/trash.md) を参照してください。

Python スクリプトは `uv run --no-project python` で実行します。uv と Ruff も mise で導入し、CI は `jdx/mise-action` で同じ lockfile から導入します。

Appleビルドの対応アーキテクチャはARM64のみです。macOSはApple Silicon、iOS SimulatorもApple Silicon Macを対象とし、Intel Mac用スライスは生成しません。

### 写真の表示上の統合

一覧は原本のハッシュ照合とは別に、原本ファイル名・リソース種別・撮影時刻が一致し、
両サービスの候補が一意な写真をまとめます。既知のハッシュが矛盾する場合や候補が
複数ある場合は分離します。この表示上の対応付けだけでは「両方に原本あり」や
移動・削除の許可にはなりません。原本の検証と転送履歴の条件は従来どおりです。

Immich はサーバーが返すスタック ID を保存し、現在閲覧できるメンバーだけを1枚に
まとめます。スタック関係から非公開・未取得のメンバーを推測して表示しません。
RAW＋JPEG 表記は実際に取得した原本の構成を示します。JPEG プレビューが生成できる
という理由だけで、RAW 単体を RAW＋JPEG と表示することはありません。
