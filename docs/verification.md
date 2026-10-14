# 検証と残タスク

## 自動チェック

`make check` で Rustfmt、Clippy all / pedantic、SwiftFormat、SwiftLint strict、Ruff、ShellCheck、actionlint、実装境界、Swift DTO の再生成差分を確認します。Swift 6 の strict concurrency と warnings-as-errors を Apple ビルドにも適用します。

`make vrt` は固定環境の専用 Simulator に simslim を適用・検証し、実際の Rust ABI から作った固定データで SwiftUI 26 画面を描画します。全画素差分、欠けた基準画像、欠けた画面を CI の別ジョブで検出します。結果と画像は `DerivedData/VRTArtifacts/` に保存します。基準画像の更新には明示的な `make vrt-record` と表示の確認が必要です。[VRT の手順](vrt.md) を参照してください。

Rust テストでは同一性、RAW/JPEG の部分一致と多重度、未照合／限定権限、scope、Copy / Move の意図、古い履歴、位置情報、撮影日時の欠落、原本変更、履歴保存失敗、削除結果不明、API ページング／sidecar を確認します。Swift テストは本物の Rust ライブラリをリンクし、Crux の effect 応答、ViewModel、エラー復旧、origin 検証、ハッシュ計算のキャンセルを確認します。原本取得のゲートでは停止要求、登録前の停止、途中ファイルの削除、遅れて到着するコールバック、チャンク順序を確認します。Git hooks の検証では既存ファイル、symlink、独自の hooksPath を保存することと、hooks 内からの実行を確認します。

`make integration` は隔離した実 Immich v3.2.4 に Rust の Crux effect を接続し、アップロード、調整済み日時・タイムゾーン・GPS、お気に入り・アルバム、一覧、バイト一致のダウンロード、編集後のプレビュー、現在の原本・編集系列の取得と再検証、スタックの全メンバー、sidecar による削除制限、ゴミ箱操作を確認します。PNGの画素・色空間・透過・日時と位置の実書き出しはmacOSのNativeテストで確認します。通常のRustテストでは実Immichの1件を明示的にignoreし、CIの専用ジョブで実行します。

`make apple-native-test` は、専用Simulatorに生成したJPEGで、製品のcore・Appleアダプターを通じた実保存、7回の起動、結果不明の読取りによる確認、キャンセル、原本への復元を検証します。全段階の原本署名・日時・位置・お気に入りと、保存／復元後の現在の寸法・色を確認します。VRTとは別の証拠で、実機／iCloud／RAWなどの受入れは残ります。[手順と範囲](native-photokit.md)を参照してください。

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
