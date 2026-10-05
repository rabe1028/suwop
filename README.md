# Suwop

Apple Photos と Immich の写真を一つの一覧で確認し、原本の保存先を確認・コピー・移動する iPhone / iPad / Mac 向け SwiftUI アプリです。

## 主な機能

- Apple Photos / Immich の統合グリッド。
- 「両方」「Apple のみ」「Immich のみ」「一部だけ両方」「未照合」を区別。
- RAW + JPEG を別原本として確認。JPEG だけバックアップ済みなら完全保存とは判定しません。
- Apple Photos ↔ Immich の両方向コピー。
- 移動は **コピー → 転送先を再取得して検証 → 別画面で確認 → 両方を再検証 → 元をゴミ箱へ** の二段階。
- API キーは Keychain に保存。
- Immich 2.x / 3.x の API 形状を分岐。現在の統合テスト基準は v3.2.4。

Live Photo、編集・補助データ付き写真、バースト、Immich External Library など、安全に削除できないケースはコピーのみです。完全削除 API は使用しません。

## 起動

必要: macOS、Xcode、XcodeGen。

```sh
brew install xcodegen
xcodegen generate
open Suwop.xcodeproj
```

Xcode で `SuwopiOS` または `SuwopmacOS` を選びます。実機では Signing の Team を設定してください。

起動後:

1. Apple Photos へのアクセスを許可。
2. Immich の URL と API キーを設定。
3. 一覧を更新。
4. 「未照合の原本を照合」を実行。iCloud 上の RAW / 動画をダウンロードすることがあります。
5. 写真詳細からコピー、または移動準備を実行。
6. 移動は「転送履歴・移動確認」から明示的に完了。

HTTPS が既定です。HTTP は設定で明示的に許可した場合のみ使います。

## 安全な移動

SHA-1 は Immich との照合用です。削除前の検証では、転送元と転送先から実際の原本を読み直し、SHA-256 とバイト長も確認します。

通信失敗、原本不足、RAW 欠落、コピー後の変更、アカウント変更、履歴保存失敗などでは元データを削除しません。削除結果が不明になった場合も自動再試行しません。

> Apple Photos の削除は、iCloud 写真が有効なら他の端末にも同期されます。「端末内キャッシュだけを消す」操作ではありません。

## テスト

通常のテスト:

```sh
make test
make test-release
```

Docker で実際の Immich を起動する統合テスト:

```sh
make integration-test
```

このテストは `docker/immich-test/docker-compose.yml` で Immich v3.2.4、PostgreSQL、Valkey を一時起動します。テスト専用ユーザーと API キーを作り、1px PNG を実際に

```text
upload → list → download → trash
```

まで実行します。終了時にテスト用コンテナと volume を削除します。

環境を残して調査する場合:

```sh
KEEP_IMMICH_TEST_ENV=1 make integration-test
make immich-down
```

GitHub Actions では Swift Debug/Release tests、Docker Immich integration、iOS Simulator build、macOS build を実行します。

## 構成

```text
Sources/SuwopCore/
  Catalog.swift        写真の同一性・保存状況
  Transfer.swift       コピー/移動の状態機械
  ImmichClient.swift   Immich API

App/
  ApplePhotos.swift    PhotoKit / Immich store
  LibraryModel.swift   永続化・Keychain・UI state
  SuwopApp.swift       SwiftUI UI

docker/immich-test/    実 Immich 統合テスト
```

詳しくは [architecture.md](docs/architecture.md) と [verification.md](docs/verification.md) を参照してください。
