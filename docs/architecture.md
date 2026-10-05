# 設計

## 写真と保存先

`AssetKey = provider + scope + assetID`。Apple の scope はアプリデータの生成時 UUID、Immich は正規化した API URL と `/users/me` の user ID です。接続先を変更しても別アカウントの ID や照合を流用しません。

`StoredAsset` は各サービス上の一枚、`PhotoResource` は原本や補助リソース、`UnifiedPhoto` は同じ原本を持つ StoredAsset をまとめた表示単位です。ファイル名・撮影日だけで同一判定しません。

Apple Photos は `PHAssetResource` を列挙し、JPEG/HEIC、RAW、動画、Live Photo 動画を別リソースとして扱います。Immich の SHA-1 は照合キーとして正規化します。RAW と JPEG の一方しか一致しない場合は「一部だけ両方」とし、全原本の集合が一致した時だけ「両方」とします。

## 移動プロトコル

`TransferCoordinator` はコピーと削除を分離します。

1. 転送元の全原本をエクスポート。
2. SHA-256 + バイト長で実データを記録。
3. 転送先へコピー。
4. 転送先から原本を再取得し、実データを再検証。
5. `copied` として履歴を永続化。ここでは元データを残す。
6. ユーザーが別操作で「移動を完了」を選ぶ。
7. 転送元・転送先・revision・原本を再検証。
8. `deletingSource` を永続化できた後だけ、転送元をゴミ箱へ移す。

状態は `copying → copied → deletingSource → moved`。削除結果が不明な場合は `deletionUncertain` とし、自動再試行しません。

Live Photo、編集・補助データ付き、バースト、Immich External Library など、安全に削除できないケースはコピーのみです。

## 実装境界

- `Sources/SuwopCore/Catalog.swift`: ドメイン・同一性・存在判定
- `Sources/SuwopCore/Transfer.swift`: 検証・移動状態機械
- `Sources/SuwopCore/ImmichClient.swift`: Immich HTTP API、ページング、multipart
- `App/ApplePhotos.swift`: PhotoKit / CryptoKit / 保存先アダプター
- `App/LibraryModel.swift`: UI 状態、Keychain、永続化、キャッシュ
- `App/SuwopApp.swift`: SwiftUI UI
- `docker/immich-test/`: 実 Immich 統合テスト環境

SHA-1 は Immich との互換照合用です。破壊的操作の判断では、実際に読み直したバイト列の SHA-256 とサイズも確認します。

## Immich API

基準は Immich v3.2.4。3.2 以降の metadata search は `filter/orderBy/cursor/nextCursor` を使い、旧 2.x は flat fields + page を使います。不明なメジャーバージョンは拒否します。

- https://api.immich.app/
- https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/search.dto.ts
- https://github.com/immich-app/immich/blob/v3.2.4/server/src/controllers/asset-media.controller.ts
- https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/asset-response.dto.ts
- https://developer.apple.com/documentation/photos/phassetresource
- https://developer.apple.com/documentation/photos/phassetresourcemanager
