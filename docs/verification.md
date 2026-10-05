# 検証

## 自動テスト

ローカルの Linux / Swift 6.2.1 では、共通コアのテストと Docker 統合テストの非 Docker 部分を実行しています。

- `swift test`: 46 tests、0 failure。Docker がないため `ImmichLiveTests` 1件は skip。
- `swift test -c release`: core tests 45件、0 failure。
- Catalog: RAW/JPEG の部分一致、未照合、権限制限、scope、関連付け。
- ImmichClient: 2.x/3.2 pagination、URL、redirect、multipart、trash。
- Transfer: コピー後の再検証、変更検知、journal failure、キャンセル、削除結果不明。

GitHub Actions ではさらに次を実行します。

- Ubuntu: Debug / Release の Swift tests。
- Docker: Immich v3.2.4 + PostgreSQL + Valkey を起動し、1px PNG を upload → list → download → trash。
- macOS: XcodeGen、iOS Simulator build、macOS build。

## 実機で確認する項目

1. Apple Photos の拒否・限定・フルアクセス。
2. JPEG、RAW+JPEG、動画、Live Photo、編集済み写真。
3. Apple → Immich と Immich → Apple のコピー。
4. RAW+JPEG で片方だけ存在する時に「一部だけ両方」と表示されること。
5. 移動準備後に転送先を変更・削除・オフライン化した場合、元を削除しないこと。
6. 正常移動では転送元だけがゴミ箱へ入ること。
7. 通信切断・アプリ終了後に削除を自動再試行しないこと。
8. Immich の接続アカウントを変えた後、古い履歴から削除できないこと。

Apple Photos の削除は iCloud 写真が有効なら他端末にも同期されます。本番データの大量移動前に、独立バックアップとテスト用写真で確認してください。
