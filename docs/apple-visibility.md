# Apple 可視性の基盤（PP-02A-1）

この段階は通常の一覧・操作から非表示の原本を隔離する基盤であり、非表示／再表示の製品 UI や新しい変更 effect はまだ提供しない。

## 保存状態と公開状態

Rust の `StoredAsset.appleVisibility` は Apple の物理 `AssetKey` ごとの `unknown` / `visible` / `hidden`。Immich の同一チェックサムのコピーは別の可視性を持ち、Apple 側の非表示だけでは除外しない。確認できない Apple 写真の名前、日時、位置、原本 revision、資源名、件数は公開する一覧から除く。

保存 schema は 3。schema 1 の日時変換と legacy Copy 意図を保ち、schema 1 / 2 の欠落した可視性は `unknown` として読む。現在の native scan で取得できた通常の Apple 写真が `visible` になる。可視性を既存 revision 文字列へ追加せず、Move の原本証拠を変更しない。アップロード履歴の原本比較も可視性とは分離し、旧履歴から fresh visible 原本で再開できるようにする。

保存する `SavedLibrary` と UI へ渡す `PublishedLibrary` は別型。公開 projection は canonical 状態を変更せず、receipt、未完了アップロード、編集貼り付け、削除記録の非公開原本情報を伏せる。結果不明の削除 ID・outcome・検査操作は残す。過去の status / error と履歴解除・編集貼り付けの確認文も同じ公開境界を通す。旧 clipboard の元 key がない場合は元名を伏せ、編集 recipe は保持する。

## 通常操作と遅延応答

通常の source 操作は current snapshot の exact physical key と可視性を確認する。古い Apple key を指定した操作が、同じ原本の Immich コピーへ自動的に切り替わることも拒否する。現在 visible な Immich コピーからの操作は可能。

新規コピーの readback は、その操作の import が返した exact destination key のみを専用経路で照合する。通常 source の membership 制限をこの新規 ID へ適用しない一方、scope・ID 集合・native 可視性・原本一致・結果不明の書込 fence は保つ。この例外は通常の画像取得や source 操作へ転用しない。

Swift native の通常 fetch と変更 queue 内の再取得は hidden 写真を拒否する。画像の取得後にも再取得する。削除結果不明の journal 検査は exact ID の facts のみを読む専用経路であり、画像へのアクセスを許可しない。

Rust が管理する非永続の Apple 観測世代は、原本取得後に到着する共有・再生・編集表示と Apple source の外部転送を停止する。Immich のみの処理は停止しない。通常の変更後の readback や一括貼り付け全体を取消す token にはしない。Swift の thumbnail cache は cache hit 前と非同期取得後に source key と世代を確認し、変更時は cache と Swift 側の敏感なエラー表示を破棄する。

## 表示中の情報と native 画面

`LibraryModel` は PhotoKit の変更通知と公開 projection から物理 key が消えた時に、cache を無効化して `AppleShell.invalidateContentPresentations()` を呼ぶ。過去の core error もそのまま残さず匿名の案内へ置き換える。Info は現在の公開写真から情報を取得し直し、Apple の対象が見えなくなった metadata 画面は日時・座標の入力を消して閉じる。同じ checksum の Immich コピーを、消えた Apple 対象の操作先として借りない。

Rust は編集表示に exact source key、再生 plan に `sourceKeys` を渡す。Apple source の editor は表示をすぐ遮蔽し、render の停止と終了待ちを行ってから取消を返す。保存ボタンで閉じ始めた後でも、可視性変更が先に検知されれば draft を返さない。player は表示と音声を停止し、読込み task の取消・終了待ちと画面の終了後に取消を返す。遅延した読込みや表示 completion から再び画面を開く・再生することを防ぐ。

Immich のみと識別できる editor / player は保持する。旧入力など source key を識別できない表示は保守的に取り消す。確認文の DTO はすべてが元 key を持つわけではないため、表示中の確認画面は保守的に閉じて `false` を返す。確認ごとの UUID で、以前の画面の遅延 callback が新しい確認へ応答することを防ぐ。

これは native 表示の取消であり、`LibraryModel` の work 全体は cancel しない。Rust はその応答を受け、必要な永続化、native 編集 session の close、作業ファイルの cleanup を続ける。書込みがすでに開始済みの場合の結果不明記録や PP-01 の削除 fence を解除する仕組みではない。

## システム共有の残制約

macOS は共有 service の選択前だけ `NSSharingServicePicker.close()` を呼び、取消の delegate 応答まで lease を保持する。選択は同期 lock で記録し、service に渡った後は表示を閉じて完了を捏造しない。[picker の close](https://developer.apple.com/documentation/appkit/nssharingservicepicker/close()) と [service 選択の契約](https://developer.apple.com/documentation/appkit/nssharingservicepickerdelegate/sharingservicepicker(_:didchoose:)) を参照。

iOS の `UIActivityViewController` は、公開 API から選択前であることを確実に判別できない。未選択の共有 picker も可視性変更だけでは自動取消せず、[completionWithItemsHandler](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/completionwithitemshandler-swift.property) まで lease と共有用ファイルを保持する。extension が利用中のファイルを早期 cleanup したり、dismiss を共有終了として即座に continuation を解決したりしない。

選択済み service や別アプリへ handoff 済みのデータは、このアプリから撤回できない。この段階は共有開始前の可視性確認と安全な lease 管理を提供し、既開始共有を一律に取り消す保証はしない。

## 検証の区別

Rust の migration、公開 serialization、canonical 不変、履歴解除の確認文、旧アップロードの再開、stale Apple anchor、共有／再生の遅延、native 通知を含む一括編集の回帰を追加した。Swift ABI の旧 schema 2 → 3 → fresh scan と、製品 `LibraryModel` の cache hit／遅延 thumbnail・preview／復帰を検証する。

2026-10-14 の最終 `make check` は Rust/FFI 215 / Swift 51 tests と全 lint・format・architecture・generated DTO・tool/hook checks を通過した。`apple-build2` は Rust 全5 Apple target、XCFramework、iOS Simulator / universal macOS の両 app build を通過した。ログは `/tmp/suwop-visibility-check-final.log` と `/tmp/suwop-visibility-apple-build2.log`。

strict VRT は `DerivedData/VRTArtifacts/20261014T115722Z-64797/report.json` で exit 0、26画面・unit10・UI7を通過した。表示中の Info / metadata と実native editor / player / confirmation の取消回帰を含む。基準画像の意図をレビューし、非公開名の扱いが変わる `apple-trash-pending.png` / `apple-trash-pending-large-text.png` の2枚だけを更新。他24枚と比較条件は保持し、最終比較は `record: false` / `passed: true`。

Native は `DerivedData/PhotoKitArtifacts/20261014T120645Z-66766/report.json` で exit 0、全15 phaseを通過した。hide callbackは `applied`、通常の取得拒否を確認したが、restoreは `photos-handoff-required`。`native_unhide_verified=false` / `hidden_original_reverified=false` / `product_hide_ui_verified=false` であり、実再表示・hidden原本の再検証・製品hide UI成功とは扱わない。最終HEADのhosted CIは未実施、実機/iCloudは未確認。

local の統合 check / Apple build / VRT / native 受入れと hosted CI は最終結果を [検証](verification.md)へ記録する。専用生成 fixture の native 非表示変更は受入れ用であり、製品の非表示 UI の完成や、実機・iCloud・ロックした Photos 非表示アルバムの可用性を証明しない。
