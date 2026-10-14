# Immich の PIN 認証付き閲覧（PP-02C-1）

実装と最終ローカル検証は完了。hosted CI、実機受入れは未完了。

既存の API キー接続を維持し、同じ接続先・利用者の専用パスワードセッションで PIN を確認する。今回の範囲は locked 写真の一覧と選択した1枚のプレビュー。サーバー上の visibility 変更は PP-02C-2 で扱う。

Rust が接続先、利用者照合、HTTP要求、PIN認証、サーバー状態照合、閲覧権限の世代と公開データを管理する。Swift は入力画面、画像取得・一時保持、scene の通知を担当する。端末認証によるアプリ内保護と Immich の PIN は独立し、Immich の認証が成功してもアプリ内保護の対象は公開しない。

パスワード・PIN・専用セッショントークンを保存しない。専用セッションの内容を通常の写真一覧や履歴へ混ぜない。画面を閉じる、非アクティブ化、接続先や保護状態の変更ではローカルの閲覧を直ちに取り消し、サーバーの lock／logout を試みる。通信結果が不明ならサーバーでの失効を確認済みとは表示しない。

閲覧の前後にサーバーの認証状態を確認する。表示中も有限の表示期限を設け、期限切れでは写真名と画像を消す。ローカル表示期限とサーバーの実際の認証期限・失効結果を区別する。実装ではHTTP応答時の状態から絶対的な期限を引き継ぎ、最大30秒の表示許可を期限前に再確認する。遅れた応答で期限を過ぎた許可を復活させない。専用セッション取得時から15分以内の固定上限は再確認で延長しない。画面側の期限切れではRustの状態取得や通信を待たず遮蔽する。

OAuth のみ、パスワードログイン無効、PIN 未設定の場合は対応範囲と必要な設定を説明する。サーバー設定を自動変更しない。

## 固定バージョンの契約

Immich v3.2.4 の [認証 controller](https://github.com/immich-app/immich/blob/v3.2.4/server/src/controllers/auth.controller.ts) と [認証 service](https://github.com/immich-app/immich/blob/v3.2.4/server/src/services/auth.service.ts) を参照する。session unlock は実セッションを要求し、logout はそのセッションを削除する。PIN のサーバー期限は要求によって延長されるため、端末の時計だけで認証成功を判定しない。

## 受入れで確認する事項

- 実サービスでの API キーによる unlock 拒否、誤った PIN、同一利用者照合、unlock／status／lock／logout。
- 一覧・画像取得前後の認証失効、閉じた後の遅延応答、再認証後に届く古い応答・タイマー。
- 通常一覧への非混入とアプリ内保護の維持、非アクティブ化時の即時遮蔽。
- キャンセルに遅れて応答する画像取得も含めた同時1件制御と、一時画像の破棄。
- 通常の品質チェック、Apple build、固定環境の strict VRT、実 Immich 結合テスト。実機・iCloud・実サーバーでの長時間経過試験は別の証拠として記録する。

## 最終ローカル検証

- `make check`: Rust/FFI262、Swift57と品質gate成功（`/tmp/suwop-locked-check-final1.log`）。
- `make apple-build`: Rust Apple全5 target／XCFramework、iOS／universal macOS成功（`/tmp/suwop-locked-apple-final1.log`）。
- strict VRT: `20261014T171524Z-90713`、35画面／Host33／UI20、`passed=true`・`record=false`。新規4枚を親レビュー後に記録し、既存31枚はbyte単位で保持。
- 実Immich v3.2.4: 専用session／PINと既存転送の結合2件成功（`/tmp/suwop-locked-integration2.log`）。以後の製品修正はSwiftの表示・画像破棄で、Rustのサービス契約は変更していない。
- PhotoKit: `20261014T170606Z-88317` の19 phase成功。これは最終のImmich画像破棄境界修正前の実行であり、最終HEADのhosted CIとは区別する。非表示はApplied、復元はPhotos handoff。直接再表示・hidden原本readback・実機／iCloudは未確認。
- 15分の実時間経過、実OSの端末認証、手動の複数ウィンドウ操作は未確認。期限・遅延応答・キャンセルは制御した回帰テストで確認した。

## 修正と再検証の記録

- Rustの期限2件、Immich契約7件、専用セッション7件が成功（`/tmp/suwop-locked-tests3.log`）。期限は制御した状態による回帰で、実際に15分経過させた実サービス試験ではない。
- DTO生成とstrict Clippyが成功（`/tmp/suwop-locked-generate2.log`、`/tmp/suwop-locked-clippy7.log`）。初期compileとlintの失敗は修正後に再実行した。
- 初回 `make apple-build` は全5 Rust Apple target／XCFramework、iOS／universal macOSで成功（`/tmp/suwop-locked-apple1.log`）。その後に認証先サーバーの表示を追加し、最終sourceでも再buildが成功した（`/tmp/suwop-locked-apple2.log`）。
- 実Immich v3.2.4結合は専用PIN経路と既存の転送経路の2件が成功（`/tmp/suwop-locked-integration2.log`）。APIキーでのunlock拒否、誤PIN、同じ利用者の専用ログイン、locked一覧・JPEGプレビューの実バイト、アプリ内の承認、close後のlock／logout応答と非公開化を確認した。15分の実時間経過や実OS画面での操作の証拠とはしない。専用Docker project `suwop-locked-20261014` のコンテナ・ボリューム・ネットワークは片付け済み。
- 初回結合テストは新しいテスト実行部分が既存のアップロード後Wait effectを扱えず失敗した。既存の広い転送テストは成功。新しい実行部分に有限のWaitを追加し、上記2件を再実行した。製品の認証処理や判定はこの修正で変更していない。修正後strict Clippyも成功（`/tmp/suwop-locked-clippy-live.log`）。
- 初回全体checkではRust/FFI262件が成功したが、新規Swift ABIテストのJSONValue同士の比較がEquatable非対応でcompile失敗した（`/tmp/suwop-locked-check1.log`）。生成型や製品処理を変えず、テスト側の型付き比較を修正して再実行する。
- 修正後の全体checkはRust/FFI262／Swift57と品質gateが成功（`/tmp/suwop-locked-check2.log`）。
- 初回VRT captureはテスト用ホストのCombine import不足でbuild失敗（`20261014T161351Z-74815`）。画面比較・Host／UIテストが通った証拠とはしない。
- 2回目のcaptureではbuildと撮影まで進んだが、通常Share拒否時のcleanup effectに対するHostテストの期待を確認中。プレビュー画像は読み込み中を撮影しており未受入れ、大きな文字ではナビタイトルが切れたため「ロック写真」へ短縮した。新規baselineはまだ記録していない（`20261014T161948Z-76693`）。タイトル変更後のbuild・VRT再実行、hosted CIは未完了。

- 2回目captureのUI19件はプレビュー待機2件が失敗し、他17件は成功。Hostの通常Share拒否テストはlock／logoutと画像破棄だけを許す検証へ修正し、内容I/O・共有・書込みが発生しないことを確認した。
- プレビューのtaskを透明なGroupから安定したVStackへ移した後、対象Hostと実Galleryのログイン／画像表示／close UIの2件が成功（`/tmp/suwop-locked-preview-diagnostic4.log`）。修正前の同じUI試験は失敗しており、画像取得単体の成功と画面表示の成功を区別した。全体VRTは再実行待ち。
- 同じGroup上のtaskを使っていた既存B画面にも、画像取得回数の成功だけでは検出できなかった表示不具合を再現した。実際の`protectedRaster`存在を要求するUI回帰は修正前に失敗（`/tmp/suwop-b-raster-diagnostic1.log`）。認証・キャンセル・遮蔽の判定を保持して同じ安定コンテナ修正を加え、再検証中。
- Bの表示修正後、実画像表示・closeでの遮蔽・Homeからアプリへ戻った後の遮蔽のUI3件が成功（`/tmp/suwop-b-raster-diagnostic3.log`）。途中のdiagnostic2はテストホストの型推論時間超過でbuild失敗し、型を明示した補助関数へ分離して再実行した。
- capture3（`20261014T164116Z-81548`）では操作UI20／撮影以外のHost30件がすべて成功。撮影caseは新規form／openのbaseline未登録に加え、UIKitの画像要素検出がtimeoutして失敗した。preview／large-textと後続画面は未撮影のため、35画面のVRT成功とはしない。form／openは親レビューで読みやすさを確認。正解画像は変更していない。
- 撮影専用の診断PNGで実際のプレビュー表示を確認し、UIKit AX列挙のfalse-negativeと判明した。VRT限定で実Image branchの配置通知を待つ方式へ変更。`C1-preview-geometry-capture`は35画面を出力し、新規4枚のbaseline未登録だけで失敗した。親が4枚を個別レビューし、プレビューの実raster、大きな文字のタイトル・折り返し・ボタンを受入れ、4枚だけの明示的記録を承認。既存31枚は保持し、記録後のstrict VRTを別途実施する。
- 明示的record実行 `20261014T165229Z-84971` は35画面／Host31／UI20、`passed=true`・`record=true`で成功。実行完了後に既存31枚をreview済みbackupとbyte単位で一致させ、新規4枚だけ追加。通常のstrict VRTは別実行で確認中（`/tmp/suwop-locked-vrt-final.log`）。
- strict VRT `20261014T165910Z-86476` は`passed=true`・`record=false`、35画面／Host31／UI20が成功。既存31枚のbyte保持を確認。PhotoKit回帰と最終check／Apple buildはこの後に別途確認する。
- PhotoKit回帰 `20261014T170606Z-88317` は19 phase成功。製品hideはApplied、restoreはPhotos handoff。直接unhide／hidden原本readback／実機・iCloudの成功とはしない。
- その後の親レビューで、Rustが送る「最後に破棄する世代」に対しnative側が同じ世代を残す境界のずれを検出。画面のshieldによる一括破棄とは独立に、破棄命令の比較を検証・修正する。上記strict VRTとPhotoKit回帰はこの境界修正前の結果であり、修正後のfocused回帰・strict VRT・check／Apple buildを再確認する。
- 境界回帰の修正前実行（`/tmp/suwop-locked-boundary-red.log`）で、同じ世代のcacheが残り取得もcancelされないことを再現。native側を「より新しい世代だけ保持／指定世代以下をcancel」へ修正。最初の再実行では破棄・cancelは成功したが、cancel後もRust grantが開いたままとするテストの期待が誤っていた。実装はread失敗時にcloseする仕様で、保持中の独立判定と完了後の安全側closeを分けて再確認する。
- 整理後の境界回帰2件は成功（`/tmp/suwop-locked-boundary-green2.log`）。保持中のlive grantを確認したままnative cancelを実行し、古い取得のcancel／未stage、完了後のRust close、古いcache破棄、新しい世代の保持を検証。最終strict VRTはHost33／UI20／35画面で再実行する。
- 境界修正後の最終strict VRT `20261014T171524Z-90713` は35画面／Host33／UI20が成功（`record=false`）。比較基準の追加更新はなく、既存31枚は保持。最終check／Apple buildを続けて確認する。
- 最終`make check`が成功（`/tmp/suwop-locked-check-final1.log`、Rust/FFI262／Swift57、品質gate成功）。Apple buildは同じ最終sourceで実行中。
