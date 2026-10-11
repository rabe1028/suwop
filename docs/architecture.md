# 設計

## Crux と実装境界

`crates/suwop-core` の `Suwop` は Crux の `App` を実装します。Swift から Event を受け、Rust の Model を更新し、ViewModel と ShellOperation の effect を返します。Swift は effect の入出力を実行して応答を Rust に戻します。状態の判断と操作の順序は Rust にあります。

- `domain.rs`: 同一性、RAW/JPEG の多重度、保存状態、削除条件、PhotoKit 入出力計画。
- `workflow.rs`: 接続、走査、照合、コピー、移動、履歴保存、旧形式の移行。
- `sharing.rs` / `workflow/sharing.rs`: 共有元の選択、原本の検証、共有ファイルの名前と作業領域の寿命。
- `metadata.rs` / `workflow/metadata.rs`: 保存先ごとの日時・位置情報、入力・権限の検証、保存結果の再取得。
- `immich.rs`: URL／origin 検証、API、ページング、multipart の仕様、レスポンス解釈。
- `crates/suwop-ffi`: Crux の JSON FFI と C ABI、ファイルをストリームでハッシュするネイティブ入出力。
- `Sources/SuwopShell`: FFI actor、JSON、生成された DTO、表示用の補助値。
- `App/AppleShell.swift`: 汎用 effect の振り分け、原子的なファイル保存。
- `App/ApplePhotos.swift`: PhotoKit の観測とリソース入出力。削除直前にも Rust に観測結果を渡す。
- `App/ApplePhotosMetadata.swift`: Rust が指定した変更だけを PhotoKit の変更キューで実行し、全 ID の最新の結果を返す。
- `App/Credentials.swift` / `HTTPExecutor.swift`: Keychain と汎用 HTTP の入出力。
- `App/SystemSharing.swift`: iOS の activity controller と macOS の sharing service。完了またはキャンセルまで effect を返さない。
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

## 原本の共有

共有は写真や転送履歴を変更しない操作です。統合された写真につき全原本を提供できる保存先を選び、同じ完全な構成なら Apple Photos を優先します。Live Photo 本体で付随動画を含められる場合は単独の動画 asset を重複選択せず、RAW / JPEG が別々の Immich asset の場合は両方を選びます。完全な組にアクセスできない場合は一方だけを共有しません。Immich が選ばれた場合だけ再接続を要求します。原本を取得した後、作業領域内へ元の名前でコピーし、SHA-1 / SHA-256 / バイト長を再検証してシステム共有画面へ渡します。位置情報を含む原本のメタデータや関連動画を保持することを UI で案内します。

Rust は native service の応答まで作業領域を保持し、その後に削除します。共有先が読み取る間に Swift Task のキャンセルでファイルを消さないようにします。native delegate は操作ごとに独立させ、以前の callback が後の共有を完了扱いにしない構成です。取得・コピー・検証が失敗した場合も作業領域を片付け、片付けの失敗は表示します。強制終了では完了 callback を受け取れず、OS の一時領域にファイルが残る場合があります。再起動時の回収は継続作業です。

## 原本の再生

Crux の `Play` が1件の catalog photo と scope / access を検証し、必要な場合だけ Immich の現在の session を取得する。Live Photo は親 asset を選び、単独の付随動画へ代替しない。プレビューの保存先も Rust が選び、Swift は指定された asset の取得だけを行う。既存の原本 export と hash 検証を経て、再生用にコピーした動画1ファイルまたは Live Photo の静止画 / 動画2ファイルを `PlayMedia` effect へ渡す。取得中に構成が変わった場合や、コピーの内容・パスを確認できない場合は再生しない。

Swift は `PlaybackPlan` の AVKit / PhotosUI 表示だけを担当する。終了時にプレーヤーを停止し、画面を閉じてから応答を返す。Rust はこの応答まで workspace を保持し、終了・失敗後に cleanup を実行する。写真と転送履歴には書き込まない。原本の再生と編集後の再生は別であり、画面に原本であることを示す。

## 日時・位置情報

情報画面で保存先を選び、その provider / scope にある関連原本の組へ1項目ずつ反映する。Rust が1件の catalog photo の完全な組、現在の scope、フルアクセス、日時と IANA time zone、有限かつ範囲内の座標を検証する。別の保存先、日時以外のメタデータ、転送履歴、原本ファイルのバイト列は変更しない。PhotoKit の creationDate は絶対日時として保存する。UI は端末のタイムゾーンを使用する。

Swift は PhotoKit の変更キュー内で権限と全 ID・properties の変更可否を再確認してから、creationDate または location だけを変更する。Immich は全 ID の所有者と状態を先に確認してから bulk PUT を1回実行する。撮影日時は UTC の dateTimeOriginal と IANA timeZone を渡す。読込でも、元ファイルの timestamp より調整後の EXIF 日時を優先する。不正な調整日時を元の日時へ置き換えず、不明として表示する。

Rust が変更後の全 ID、日時または座標と Immich の timeZone を再取得して確認し、最新のレコードを保存する。応答の欠落・重複・値の不一致・保存失敗は変更済みの可能性を表示し、保存先への変更を一覧の再読込まで無効にする。自動で再試行しない。独立したメタデータ変更は新しい削除用の証拠を作らず、古い revision の照合証拠を流用しない。

位置情報の削除は PhotoKit の location = nil のみ対応する。Immich v3.2.4 の更新 DTO は null 座標を受け付けないため、削除を提供しない。0 / 0 は実在する座標として保存する。ライブラリの位置情報を変更しても、共有する原本ファイルの EXIF を除去したことにはならない。地名検索・地図、任意タイムゾーンの選択、取り消し・元の値への復元は継続作業。

## API 基準

Immich v3.2.4 を実通信テストに使用します。3.2 以降は filter / orderBy / cursor、旧 2.x / 3.0–3.1 は flat fields / page を使います。実通信の証拠は v3.2.4 のみで、旧 API 形状は契約テストで確認します。不明なメジャー、ページ情報の欠落・循環は拒否します。

- [Crux Apple shell](https://redbadger.github.io/crux/part-1/shell/apple/index.html)
- [Immich asset DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/asset.dto.ts)
- [Immich search DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/search.dto.ts)
- [PhotoKit resources](https://developer.apple.com/documentation/photos/phassetresource)
