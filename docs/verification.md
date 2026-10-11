# 検証と残タスク

## 自動チェック

`make check` で Rustfmt、Clippy all / pedantic、SwiftFormat、SwiftLint strict、Ruff、ShellCheck、actionlint、実装境界、Swift DTO の再生成差分を確認します。Swift 6 の strict concurrency と warnings-as-errors を Apple ビルドにも適用します。

Rust テストでは同一性、RAW/JPEG の部分一致と多重度、未照合／限定権限、scope、Copy / Move の意図、古い履歴、位置情報、撮影日時の欠落、原本変更、履歴保存失敗、削除結果不明、API ページング／sidecar を確認します。Swift テストは本物の Rust ライブラリをリンクし、Crux の effect 応答、ViewModel、エラー復旧、origin 検証、ハッシュ計算のキャンセルを確認します。原本取得のゲートでは停止要求、登録前の停止、途中ファイルの削除、遅れて到着するコールバック、チャンク順序を確認します。Git hooks の検証では既存ファイル、symlink、独自の hooksPath を保存することと、hooks 内からの実行を確認します。

`make integration` は隔離した実 Immich v3.2.4 に Rust の Crux effect を接続し、アップロード、調整済み GPS、一覧、バイト一致のダウンロード、スタックの全メンバー、sidecar による削除制限、ゴミ箱操作を確認します。通常の Rust テストではこの1件を明示的に ignore し、CI の専用ジョブで実行します。

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
