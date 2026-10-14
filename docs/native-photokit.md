# PhotoKit の実保存テスト

```sh
make setup-vrt
make apple-native-test
```

VRTと同じ固定環境・専用Simulator・checkout lockを使う。一台を順番に使い、並列クローンを作らない。
simslimでは`photos`カテゴリーを残し、プロファイル一致とPhotosサービスの稼働を検査する。
他のSimulatorや実機の写真ライブラリには接続しない。テスト後はSimulatorを停止する。

製品のRust coreとAppleアダプターを別bundleのテスト専用ホストへコンパイルする。
確認への回答、テスト用の編集ドラフト、保存済み応答の意図的な消失をテストが制御する。
可視性のシナリオだけは、別の生成fixtureをテスト専用のPhotoKitコードで非表示・再表示する。
これは外部アプリでの変更を模したもので、製品の非表示UIや非表示effectの実装証拠ではない。
Photosのスキャン・原本取得・編集セッション・実保存・現在の画像の取得・復元・アプリ内状態の保存は製品コードを使う。
製品アプリにはこのホストとシナリオを含めない。ホストの書込み対象は作成したfixtureのIDに限定する。

最初の3枚のJPEGを使う既存12段階の後に、別の4枚目を作る可視性3段階を加え、
次の15段階でアプリのプロセスを終了・起動する。

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
13. 別の生成JPEGをPhotoKitで非表示にする。送信前のunknown記録とnative callbackのAppliedを保存する。
14. 次の起動で製品coreの通常scan・公開projectionから除外され、thumbnail/export/currentImageが拒否され、共有のRust effectも発行されないことを確認。
15. hidden assetをfresh fetchできる場合だけ再表示し、通常read・原本署名・日時/位置/お気に入り・全サイズ画像の回復を確認する。
    取得できなければ書込みを要求せず、Photosでの認証・再表示が必要な境界として別の結果を記録する。

異なるサイズの写真も含む。削除対象外として残る fixture の原本・メタデータは全段階で読み直す。既存の写真は読取りだけで、変更・削除しない。
通常削除するのは、今回の manifest に記録した生成 fixture の2枚だけで、3枚目と他の写真は保持する。権限設定が再インストールで失われた場合は、テストアプリの公開APIの要求に対し、
確認済みの「フルアクセスを許可」をXCUITestで操作する。権限の確認前にfixtureを作らない。
非表示変更するのは別manifestに記録する4枚目だけ。既存写真は変更せず、変更前後の対象外ID集合・revisionを確認する。
対象外の全原本のハッシュ検査をした意味ではない。3枚目のcontrolは既存の原本署名・メタデータ検査を続ける。
hiddenの認証設定は変更しない。full accessでも取得できない場合があり、auth OFFを前提にしない。
native hideの成功はcallbackで確認し、通常scanから消えたことだけを成功の根拠にしない。
callback不明・明確な失敗・記録保存失敗では段階を失敗として終了し、自動で同じ変更を再送しない。
各可視性fixtureの記録はUUID別ファイルに保存し、次のrunでも以前のunknown記録を上書きしない。

CIはVRTの後に同じSimulatorで実行する。成果物は`DerivedData/PhotoKitArtifacts/<日時>-<ID>/`に保存する。
実行ログ、各起動のスクリーンショットを含むxcresult、プロファイル・Photosサービス検査、メモリと工程時間を保持する。
15段階がそれぞれ一度通過し、hideのAppliedと可視性回復の結果がそれぞれ一度記録されなければ、coverage gateは失敗する。
`report.json`の`visibility.native_unhide_verified`と`hidden_original_reverified`は実再表示・readback時だけtrue。
`photos-handoff-required`ではfalseとなり、取得拒否とPhotos案内の境界の証拠に限る。
restore段階のPASSだけでは再表示成功を意味しない。`product_hide_ui_verified`は常にfalse。
VRTの基準画像は変更しない。

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

## 可視性シナリオの証拠状態

成功runは `DerivedData/PhotoKitArtifacts/20261014T120645Z-66766/report.json`。スクリプトは exit 0、`passed: true`、既存12＋可視性3の全15段階が一度ずつ通過した。
生成した4枚目の外部hideはOS確認へ回答した後のnative callbackが `applied`。次の起動の通常scan/projection・thumbnail/export/currentImage・Rust共有effectで拒否を確認した。
restore結果は `photos-handoff-required` で、fresh hidden assetを取得できず、再表示の書込みは要求していない。
`native_unhide_verified=false` / `hidden_original_reverified=false` / `product_hide_ui_verified=false`。
restoreのPASSは取得拒否とPhotos案内の境界の通過であり、再表示成功でも4枚目の非表示後の原本再検証でもない。3枚目のcontrol原本・メタデータと対象外ID/revisionの検証は継続した。

先行実行はvisibility-hideのOS確認に応答できず失敗した。UITestをphase専用のhost名・期待Hide/Unhide・拒否buttonの照合へ修正し、次のseedが作った新fixtureで上記成功runを実行した。先行fixtureのunknown記録は再送・上書きしない。
Photosでの実再表示、PhotosPicker後の原assetへのアクセス、製品のhide/unhide操作は別の受入れである。
最終HEADのhosted CIは未実施、実機/iCloudは未確認。
