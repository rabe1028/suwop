# 設計

## Crux と実装境界

`crates/suwop-core` の `Suwop` は Crux の `App` を実装します。Swift から Event を受け、Rust の Model を更新し、ViewModel と ShellOperation の effect を返します。Swift は effect の入出力を実行して応答を Rust に戻します。状態の判断と操作の順序は Rust にあります。

- `domain.rs`: 同一性、RAW/JPEG の多重度、保存状態、削除条件、PhotoKit 入出力計画。
- `workflow.rs`: 接続、走査、照合、コピー、移動、履歴保存、旧形式の移行。
- `immich.rs`: URL／origin 検証、API、ページング、multipart の仕様、レスポンス解釈。
- `crates/suwop-ffi`: Crux の JSON FFI と C ABI、ファイルをストリームでハッシュするネイティブ入出力。
- `Sources/SuwopShell`: FFI actor、JSON、生成された DTO、表示用の補助値。
- `App/AppleShell.swift`: 汎用 effect の振り分け、原子的なファイル保存。
- `App/ApplePhotos.swift`: PhotoKit の観測とリソース入出力。削除直前にも Rust に観測結果を渡す。
- `App/Credentials.swift` / `HTTPExecutor.swift`: Keychain と汎用 HTTP の入出力。
- `App/LibraryModel.swift` / `SuwopApp.swift`: ViewModel の公開、画像キャッシュ、SwiftUI。

PoC では Crux の `JsonFfiFormat` を小さな C ABI で公開します。Rust の JSON Schema から Swift DTO を生成し、生成差分と実ライブラリをリンクしたテストを CI に含めます。FFI の unsafe は `suwop-ffi` の ABI 境界に限定します。原本のハッシュ計算は Rust の atomic なキャンセル状態を各読み取り前後に確認し、Swift の Task キャンセルを停止要求へ伝えます。PhotoKit 原本はキャンセル可能な `requestData` でチャンクごとに書き込み、停止時には native request の停止と途中ファイルの削除を行います。Swift 側は actor を使い、PhotoKit のキャンセル用ゲートだけロックの不変条件を明記した `@unchecked Sendable` を使います。

## 写真と保存先

`AssetKey = provider + scope + assetID`。Apple の scope はアプリデータ生成時の UUID、Immich は正規化した API URL と利用者 ID です。別アカウントの照合を流用しません。

`StoredAsset` は各サービス上の一枚、`PhotoResource` は原本・補助リソース、`UnifiedPhoto` は同じ原本を持つ写真をまとめた表示単位です。ファイル名や撮影日では同一判定しません。SHA-1 は Immich の互換照合用、削除前の原本検証は SHA-256 とバイト長です。RAW、JPEG、動画は個数も比較します。未照合、権限制限、オフラインを「片側に存在しない」証拠として扱いません。

## 移動と永続化

1. 転送元の全原本をエクスポートし、実バイトの署名を記録。
2. `copying` と Copy / Move の意図を保存してからアップロード。
3. 転送先の原本を再取得し、署名を検証。Move では位置情報も確認。
4. `copied` を保存。元データは残す。
5. Move として準備された履歴だけ、別操作で完了できる。
6. 両側の原本、revision、位置情報、保存先の利用者、削除条件を再検証。
7. `deletingSource` の保存成功後だけゴミ箱操作を実行。
8. 成功は `moved`、応答が不明なら `deletionUncertain`。終端状態は再試行しない。

保存形式は schemaVersion 2、日時は UNIX 秒です。旧 schemaVersion 1 の Apple 基準日時を変換し、意図が記録されていない旧履歴は全て Copy にします。不正または未来の形式は処理を停止し、元ファイルを上書きしません。

独立 asset が同じバイト列を持つ場合、編集・補助データ、Live Photo、バースト、External Library、未確認の保存種別、sidecar がある場合はコピーのみです。Immich の公開 API に `isExternal` がない場合は `libraryId` を確認します。フィールド欠落と明示的な null を区別し、欠落を内部保存の証拠にしません。

Immich への新規アップロード後に調整済みの位置情報を PUT します。既存の重複写真の独立メタデータは変更しません。位置情報が一致しない場合、Move の検証は失敗します。Immich の API は位置情報の null 更新を受け付けないため、位置情報なしの原本と EXIF 付き転送先が一致しない場合も削除を止めます。

## API 基準

Immich v3.2.4 を実通信テストに使用します。3.2 以降は filter / orderBy / cursor、旧 2.x / 3.0–3.1 は flat fields / page を使います。実通信の証拠は v3.2.4 のみで、旧 API 形状は契約テストで確認します。不明なメジャー、ページ情報の欠落・循環は拒否します。

- [Crux Apple shell](https://redbadger.github.io/crux/part-1/shell/apple/index.html)
- [Immich asset DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/asset.dto.ts)
- [Immich search DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/search.dto.ts)
- [PhotoKit resources](https://developer.apple.com/documentation/photos/phassetresource)
