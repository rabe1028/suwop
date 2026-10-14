# 検証と残タスク

## 自動チェック

`make check` で Rustfmt、Clippy all / pedantic、SwiftFormat、SwiftLint strict、Ruff、ShellCheck、actionlint、実装境界、Swift DTO の再生成差分を確認します。Swift 6 の strict concurrency と warnings-as-errors を Apple ビルドにも適用します。

`make vrt` は固定環境の専用 Simulator に simslim を適用・検証し、実際の Rust ABI から作った固定データで SwiftUI 26 画面を描画します。全画素差分、欠けた基準画像、欠けた画面を CI の別ジョブで検出します。結果と画像は `DerivedData/VRTArtifacts/` に保存します。基準画像の更新には明示的な `make vrt-record` と表示の確認が必要です。[VRT の手順](vrt.md) を参照してください。

Rust テストでは同一性、RAW/JPEG の部分一致と多重度、未照合／限定権限、scope、Copy / Move の意図、古い履歴、位置情報、撮影日時の欠落、原本変更、履歴保存失敗、削除結果不明、API ページング／sidecar を確認します。Swift テストは本物の Rust ライブラリをリンクし、Crux の effect 応答、ViewModel、エラー復旧、origin 検証、ハッシュ計算のキャンセルを確認します。原本取得のゲートでは停止要求、登録前の停止、途中ファイルの削除、遅れて到着するコールバック、チャンク順序を確認します。Git hooks の検証では既存ファイル、symlink、独自の hooksPath を保存することと、hooks 内からの実行を確認します。

`make integration` は隔離した実 Immich v3.2.4 に Rust の Crux effect を接続し、アップロード、調整済み日時・タイムゾーン・GPS、お気に入り・アルバム、一覧、バイト一致のダウンロード、編集後のプレビュー、現在の原本・編集系列の取得と再検証、スタックの全メンバー、sidecar による削除制限、ゴミ箱操作を確認します。PNGの画素・色空間・透過・日時と位置の実書き出しはmacOSのNativeテストで確認します。通常のRustテストでは実Immichの1件を明示的にignoreし、CIの専用ジョブで実行します。

`make apple-native-test` は、専用Simulatorに生成したJPEGで、15段階の再起動、製品core・Appleアダプターを通じた実保存、結果不明の読取りによる確認、キャンセル、原本への復元、通常削除、外部の非表示変更後の取得拒否を検証します。残るcontrolの原本署名・日時・位置・お気に入りと、保存／復元後の現在の寸法・色を確認します。非表示assetを取得できない場合はPhotos案内の境界を記録し、再表示成功やそのhidden原本の再検証とは扱いません。VRTとは別の証拠で、実機／iCloud／RAWなどの受入れは残ります。[手順と範囲](native-photokit.md)を参照してください。

`make apple-build` は iPhone / Simulator / Mac の Rust 静的ライブラリを XCFramework にまとめ、iOS Simulator と macOS のアプリをビルドします。これは PhotoKit 実機動作の確認とは別です。

## 残タスク: 実機での受け入れ

以下はまだ実機で確認していません。

1. Apple Photos の拒否、限定、フルアクセスと権限の変更。
2. JPEG、RAW+JPEG、動画、Live Photo、編集済み、バースト、iCloud のみの原本。
3. Apple → Immich と Immich → Apple のコピー、および位置情報・お気に入りの保持。
4. RAW/JPEG が一部だけ保存された際の表示。
5. 移動準備後の原本変更、転送先削除、アカウント変更、通信断で元を残すこと。
6. 正常移動で転送元だけがゴミ箱に入り、iCloud 同期の挙動が想定どおりであること。
7. コピー履歴、旧履歴、削除結果不明の履歴から削除できないこと。
8. アプリ終了／再起動後の履歴復旧、大量の原本照合、画面操作のキャンセル。

PoC の次の優先順位は、テスト用の小さな実機写真ライブラリでの受け入れ、RAW / Live Photo / iCloud のケース追加、大量ライブラリの性能計測です。Apple の使用許可文言、署名、配布用設定の確認も残っています。


## Apple の通常削除と復元案内

[通常削除と復元](trash.md)、[Photos parity ロードマップ](implementation-roadmap.md)。
通常削除は Move と独立した Rust 操作・永続意図・native callback outcome を持つ。
結果不明からの読取りは可視性だけを検査し、Recently Deleted 所属や復元可能性を証明しない。
ローカル Rust / 実FFI、Apple build、VRT、専用生成JPEGの native PhotoKit、最終HEAD hosted CI、実機／iCloud は別の証拠として記録する。


- `make apple-native-test`: `20261014T090310Z-85811` が exit 0、12段階・coverage・停止が通過。
  先行2回の OS ボタン selector の失敗とは区別する。生成JPEGの単独通常削除・確認取消・応答消失と再起動の証拠であり、実機／iCloud／native batch／Photos アプリでの実復元は未確認。


- 最終 `make check` は Rust/FFI 200 tests、Swift 50 testsと全 lint・format・architecture・generated DTO・tool/hook checks を通過した。
- 最終 `make vrt` は `DerivedData/VRTArtifacts/20261014T092347Z-93864/` で exit 0。26画面、5 UI tests、固定環境とcoverageを通過し、`record: false` / `passed: true`。
- 画面レビュー後に明示 `make vrt-record` を実行し、変更は `photo-info.png` と Apple 削除案内・結果不明・大文字の新規3枚に限定した。他の基準画像は保持した。大文字の List は lazy layout とスクロール後の glass 描画を待つ。RGB 2の比較条件・pixel budget・maskは変更していない。
- ローカルの実装・上記検証と、最終 pushed HEAD の hosted CI、実機／iCloud／native 複数選択／Photos アプリでの実復元は別の証拠である。

- 最終 `make apple-build` は Rust 全5 Apple target / XCFramework、iOS Simulator と universal macOS の両 app build が exit 0。native / VRT / check 完了後に直列で実行した。


## PR #20 の review 修正

削除 completion からの更新を、LibraryModel の work 解放後に pendingRefresh から開始する。
Applied / NotApplied / Unknown のすべてで読取り更新し、明確な拒否後は full-access の一覧を回復する。
自動更新は元のエラー案内を消さず、Unknown の journal と書込み拒否は保持する。
実 RustRuntime と製品 send/defer を通す VRT unit test は3結果すべてを検証し、`20261014T100857Z-20693` で通過した。
同 run は26画面・unit3 tests・UI5 testsの strict 比較を通過し、基準画像は変更していない。

アルバムの保護対象は Add / Remove の edit.keys。Unknown の Apple 削除と同じ原本がアルバムに含まれていても、rename / delete と無関係な写真の Add / Remove は許可する。
本人所有権の変更と Unknown 対象への Add / Remove を拒否し、journal・写真・receiptを保持する回帰テストを追加した。
新しい最終HEADの hosted CI と review の解消は別に確認する。PhotoKit adapter / native mutation の経路は今回変更しておらず、local Native12の証拠を今回再実行したものとして扱わない。

review 修正後の最終 `make check` は Rust/FFI 202 tests・Swift 50 tests と全品質gateを通過。`make apple-build` は Rust 全5 target・XCFramework・iOS Simulator / universal macOS 両 app build を通過した。確認は source 固定・直列で実行した。

## PP-02A-1 可視性基盤の初回 local evidence（2026-10-14、review 修正前）

- 最終 `make check` は Rust/FFI 215 / Swift 51 tests と全 lint・format・architecture・generated DTO・tool/hook checks を通過。`apple-build2` は Rust 全5 Apple target、XCFramework、iOS Simulator / universal macOS 両 app build を通過。ログは `/tmp/suwop-visibility-check-final.log` と `/tmp/suwop-visibility-apple-build2.log`。
- strict VRT は `DerivedData/VRTArtifacts/20261014T115722Z-64797/report.json` で exit 0、`record: false` / `passed: true`。26画面・unit10・UI7 testsを通過。cacheと遅延画像、旧core errorの匿名化、表示中Info/metadataおよび実native editor/player/confirmationの取消回帰を含む。
- 基準画像は表示レビュー後に意図的に更新した `apple-trash-pending.png` と `apple-trash-pending-large-text.png` の2枚のみ。非公開のApple原本名を伏せるprojectionに合わせた変更で、他24枚と比較条件は保持した。
- Native は `DerivedData/PhotoKitArtifacts/20261014T120645Z-66766/report.json` で exit 0 / `passed: true`、既存12＋可視性3の全15 phaseが一度ずつ通過。外部PhotoKit hideのcallbackは `applied`、次の起動で通常scan/projection・thumbnail/export/currentImageとcore共有の拒否を確認。restore結果は `photos-handoff-required`。
- Native reportの `native_unhide_verified=false` / `hidden_original_reverified=false` / `product_hide_ui_verified=false` を維持する。このrunは直接再表示、hidden原本の再検証、製品hide UIの成功を証明しない。Photosでの実再表示・PhotosPicker後の原assetへのアクセスも別の受入れ。
- 最終HEADのhosted CIは未実施。実機／iCloudは未確認であり、Simulatorの証拠で代替しない。設計と共有の残制約は [Apple可視性基盤](apple-visibility.md) を参照。

## PR #21 の共有 review 修正（2026-10-14）

共有 effect に実際に読み出した物理 `sourceKeys` を渡し、macOS の Apple 可視性変更が Immich のみの共有 picker を閉じないようにした。Apple source を含む共有と元キー不明の旧形式は選択前だけ取り消し、選択済み service と iOS の completion lease は保持する。

- 修正後の最終 `make check` は exit 0、Rust/FFI 216 / Swift 52 tests と全品質 gateを通過。ログは `/tmp/suwop-sharing-review-check2.log`。
- 修正後の `make apple-build` は exit 0、Rust 全5 Apple target / XCFramework と iOS Simulator / universal macOS 両 app buildを通過。ログは `/tmp/suwop-sharing-review-apple2.log`。
- `make sharing-test` は `/tmp/suwop-sharing-review-native7.log` で exit 0、macOS component tests 2件を通過。Immich のみは close 0回、Apple／混在／旧形式は選択前 close 1回。選択後の可視性変更と遅延した取消 callbackでも leaseを保持し、service完了まで解決しないことを確認。結果は `DerivedData/Sharing/Logs/Test/Test-SuwopSharing-2026.10.14_21-39-04-+0900.xcresult`。
- 先行 sharing-test の失敗は専用 fixture の key window確立に失敗したもので、成功結果とは区別する。最終 component testは test-only の view / show / close hookと実picker delegateを使う。本番の key window guardは保持し、実macOS共有UI／手動操作／外部serviceへのhandoff成功は未検証。
- 上記26画面・unit10・UI7の strict VRTと Native15は review修正前 HEAD `9e8f6f7` の証拠。共有修正後のローカル再実行結果とは扱わない。基準画像に追加変更はない。
- 修正後の最終 pushed HEADの hosted CIは確認待ち。実機／iCloudと Photosでの直接再表示は引き続き未確認。

## PR #21 の表示登録競合修正（P1、最終ローカル検証）

`ca13f38` の共有修正後に、Appleの通知が active表示登録より先に来た場合の取消漏れを修正した。Swift shellの文脈を `LibraryModel.send`／NativeAcceptance event開始前に取得し、workflow中に取り直さず全 effectへ渡す。native登録直前と読取り専用検査の await後に検査し、古い Apple／旧形式の表示を拒否する。確認は `false`、その他の表示は取消を返す。Immichのみの sourceは保持し、Rust workflow全体の取消・書込み結果・journal／lease／cleanupの意味は変えない。

追加回帰の sourceは、実 sendの最初の effect前／共有 effect発行後の競合、共有・editor・player・確認の登録拒否、ペースト／復元検査中の通知、古い文脈でも Immichの表示と完了待ち leaseを維持するケースを含む。対象 SwiftFormat／strict SwiftLintと diff checkは通過した。

今回の source固定後の最終ローカル検証は以下の通り。

- `make check`: exit 0、Rust/FFI 216 / Swift 52 testsと全品質 gateを通過。ログ `/tmp/suwop-presentation-epoch-check2.log`。
- `make apple-build`: exit 0、全5 Rust Apple target／XCFrameworkとiOS Simulator／universal macOS両 app buildを通過。ログ `/tmp/suwop-presentation-epoch-apple.log`。
- `make sharing-test`: exit 0、macOS component 2件を通過。ログ `/tmp/suwop-presentation-epoch-sharing.log`、結果 `DerivedData/Sharing/Logs/Test/Test-SuwopSharing-2026.10.14_22-04-17-+0900.xcresult`。実macOS共有UI／外部service handoffの成功とは区別する。
- strict `make vrt`: exit 0、`DerivedData/VRTArtifacts/20261014T130612Z-3518/report.json` は `passed: true`／`record: false`。26画面・unit15・UI7を通過。実 `LibraryModel.send` の固定文脈と、ペースト／復元両方の読取り検査中の競合、Apple／旧形式の登録拒否、Immich表示・lease保持の回帰を含む。基準画像の追加変更はない。
- 先行VRTはテストhelperの `@escaping` 欠落によるコンパイル失敗。test-only修正後の上記成功runとは区別する。

以前のNative15は `9e8f6f7` の証拠として保持し、P1修正後のローカル再実行とは扱わない。共有修正HEAD `ca13f38` の hosted CI run `38565835960` は全4 job成功確認済み。P1修正後の最終 pushed HEADの hosted CIは確認待ち。実機／iCloud／Photosでの直接再表示／実macOS共有UIは引き続き未確認。

## PR #21 の重複指紋・移動理由の匿名化（P2、最終ローカル検証）

公開cloneの private Apple sourceに重複する upload resource／signatureと、private sourceまたはdestinationを含むreceiptのaggregate signaturesを除去した。private履歴の公開moveBlockersは一般的な可視性案内に置き換える。canonicalの証拠・削除判定と、公開Immichの独立証拠、復旧・解除用IDは保持する。DTO／schema変更はない。

- `make check` の再実行は成功。`/tmp/suwop-private-evidence-check2.log` はRust/FFI218／Swift52 testsと全品質 gateを通過。whole-viewからdistinct hash／bytes／resource情報／private blocker文が消え、Hidden・Unknown・一覧Unavailableでもcanonical不変と公開Immichの証拠保持を確認する追加2件を含む。
- 最初のcheckは新テストの不要な `Result` 戻り値をClippyが検出して失敗。assertを保持したtest-only修正後の上記成功とは区別する。
- P2の `make apple-build` は exit 0、全5 Rust Apple target／XCFrameworkとiOS Simulator／universal macOS両 app buildを通過。ログ `/tmp/suwop-private-evidence-apple.log`。
- P2の strict `make vrt` は exit 0、`DerivedData/VRTArtifacts/20261014T132634Z-12640/report.json` は `passed: true`／`record: false`。26画面／unit15／UI7を通過。以前のP1の結果と今回の再実行結果は別の証拠として記録する。
- 前HEAD `03331a9` の hosted CIはcore／Immich integration／apple成功、VRT失敗。metadata editorのdismiss直後のUI assertionで失敗した。失敗ログは `/tmp/suwop-ci03331a9-vrt/VRTArtifacts/20261014T131134Z-1961/compare.log`。テストを有限時間の終了待ちへ修正し、上記local VRTで当該UI回帰は11.8秒で通過。本番の終了処理はこのテスト修正で変更していない。
- P2修正後の最終 pushed HEADの hosted CIは確認待ち。前HEADのVRT失敗を成功として扱わない。
- 基準画像の追加更新はしていない。実機／iCloud／Photosでの直接再表示／実macOS共有UIと外部service handoffは引き続き未確認。
