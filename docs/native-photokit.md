# PhotoKit の実保存テスト

```sh
make setup-vrt
make apple-native-test
```

VRTと同じ固定環境・専用Simulator・checkout lockを使う。一台を順番に使い、並列クローンを作らない。
simslimでは`photos`カテゴリーを残し、プロファイル一致とPhotosサービスの稼働を検査する。
他のSimulatorや実機の写真ライブラリには接続しない。テスト後はSimulatorを停止する。

製品のRust coreとAppleアダプターを別bundleのテスト専用ホストへコンパイルする。
確認への回答、テスト用の編集ドラフト、保存済み応答の意図的な消失だけをテストが制御する。
Photosのスキャン・原本取得・編集セッション・実保存・現在の画像の取得・復元・アプリ内状態の保存は製品コードを使う。
製品アプリにはこのホストとシナリオを含めない。ホストの書込み対象は作成したfixtureのIDに限定する。

3枚のJPEGを作成し、次の12段階でアプリのプロセスを終了・起動する。

1. 原本のバイト署名と日時・位置・お気に入りを記録し、切り抜き・色・セピアを実保存して編集をコピー。
2. 次の起動で保存された編集、描画サイズ・色の画素、アプリ内クリップボードを再取得。
3. 2枚への貼り付けを開始し、1枚目の実保存後に応答だけを失わせ、後続停止と送信前の記録を確認。
4. 次の起動で結果不明を読取りだけで解消し、書込み再送がないことを確認。残る写真に明示的に貼り付け。
5. 次の起動で両方の編集・現在の画素・サイズを再取得し、編集キャンセルで保存が起きないことを確認。
6. 確認後の原本への復元を、各fixtureに実行。
7. 次の起動で編集がないこと、元のサイズと青い画素、原本のバイト署名とメタデータを確認。
8. Rust が要求するアプリの削除確認をキャンセルし、native 削除を要求しないことを確認。
9. PhotoKit の実削除確認を XCUITest でキャンセルし、明確な NotApplied 応答と元写真の保持・記録の完了を確認。
10. 1枚の生成JPEGを通常削除し、native の成功応答・記録の完了と full-access fetch で見えないことを確認。
11. 別の1枚を実削除した後に応答だけを失わせ、結果不明の記録を保持することを確認。
12. 次の起動で可視性だけを検査し、対象が見えなくても記録を解除せず、削除の再送もないことを確認。

異なるサイズの写真も含む。削除対象外として残る fixture の原本・メタデータは全段階で読み直す。既存の写真は読取りだけで、変更・削除しない。
通常削除するのは、今回の manifest に記録した生成 fixture の2枚だけで、3枚目と他の写真は保持する。権限設定が再インストールで失われた場合は、テストアプリの公開APIの要求に対し、
確認済みの「フルアクセスを許可」をXCUITestで操作する。権限の確認前にfixtureを作らない。

CIはVRTの後に同じSimulatorで実行する。成果物は`DerivedData/PhotoKitArtifacts/<日時>-<ID>/`に保存する。
実行ログ、各起動のスクリーンショットを含むxcresult、プロファイル・Photosサービス検査、メモリと工程時間を保持する。
12段階がそれぞれ一度通過した証拠がなければ、coverage gateは失敗する。VRTの基準画像は変更しない。

この証拠の範囲は、固定Simulatorの生成JPEGと製品のcore・アダプター。実機・iCloud・HDR・RAW・Live Photo・
動画・native 複数選択の通常削除・Photos アプリでの実復元・外部アプリの既存編集・大量ライブラリ・OS再起動を通過した証拠としては扱わない。

## 現在の画像のフルサイズを保持する修正

実テストで、241×120の保存済み画像に対し`PHImageManager`が240×120の派生JPEGを返すことを確認した。
現在の画像の書き出しは、`PHContentEditingInput`で既存編集を解釈しない回答をして、最新の編集済みフルサイズファイルをコピーする。
再エンコードや画素展開を追加せず、向きと前後の写真の世代を検証する。キャンセル時はコピーworkerの終了を待つ。
[AppleのcanHandleAdjustmentDataの説明](https://developer.apple.com/documentation/photos/phcontenteditinginputrequestoptions/canhandleadjustmentdata)が、この回答で最新の編集済みデータを取得する挙動を説明している。

修正後の最終Native実行は`DerivedData/PhotoKitArtifacts/20261013T000846Z-54484/`。
7回の起動をすべて通過し、奇数幅241画素、セピアの現在の画素、復元後のサイズ・元の青い画素、原本とメタデータを確認した。
coverage gateには実行済み段階がないログを与えて失敗することも確認した。


## Apple 通常削除の local native evidence（2026-10-14）

`make apple-native-test` の成功 run は `DerivedData/PhotoKitArtifacts/20261014T090310Z-85811/`。
12段階がそれぞれ一度通過し、native test・coverage・Simulator停止を含むスクリプトは exit 0、`report.json` は `passed: true`。
アプリ確認キャンセルでは削除 effect がなく、OS の「Don’t Allow」では PhotoKit の NotApplied 応答・記録の完了・原本保持を確認した。
通常削除の成功後は PhotoKit 応答の永続化と選択した1枚だけの一覧除外を確認した。
別の1枚の実削除後に応答を失わせ、再起動後は full access で見えないことを観測しても結果不明の記録を解除せず、書込みを再送しない。
削除対象外の生成JPEGの原本署名とメタデータは保持された。

先行2 run（`20261014T085629Z-82777` / `20261014T090104Z-84989`）は OS ダイアログの選択文字列の不一致でテストが失敗した。
実画面と AX hierarchy に合わせて SpringBoard の typographic apostrophe を含む `Don’t Allow` を選ぶよう修正し、成功 run を別に実行した。
この失敗 run を通常削除の成功には数えない。診断回収では Xcode が `simctl` を探せない警告が残るが、成功 run の xcresult・工程ログ・coverage・report と停止は生成された。
実機、iCloud、RAW／Live／burst の native 削除、native 複数選択、Photos アプリでの実復元は未確認。
