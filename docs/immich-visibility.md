# Immich のロック移動・再表示（PP-02C-2）

実装・検証中。固定したImmich v3.2.4の実サーバー結合は成功したが、C-2のhosted CIと最終画面検証は未完了。C-1の専用PINセッションはPR #24でmerge済みで、最終HEADとmerge後のCI全4 jobが成功している。

最初の増分は、同じ利用者が所有する、関連動画とstackを持たない静止画のtimeline／archiveからlockedへの変更と、lockedから明示的に選択したtimeline／archiveへの変更を扱う。Live Photo、動画、関連状態が不明な写真は対応済みとしない。通常のtimelineとarchiveの相互変更は、PIN不要の別経路として残す。

## 操作と永続記録

表示中の物理的なImmich表示元を指定し、同一接続先・利用者の専用セッションで認証する。ロックによりすべてのアルバムから外れ、再表示しても所属が自動復元されないことを確認画面で伝える。確認後に認証・scene・同一写真・revisionを再検査する。GETからPUTまでの競合を排除するCAS契約はない。

変更要求にはRustが発行した認証・scene・世代・期限を付け、native側でも送信直前に照合する。認証を閉じる処理と通信タスクの送信開始を同期し、待機中に失効した要求は送信しない。送信開始後に閉じた場合は応答を受け取り、再照合できなければ結果不明の記録を保持する。

iOSの確認は専用sheetで説明をスクロール可能にし、Dynamic Typeに応じた高さの確定・キャンセルボタンを表示する。Rustが認可したscene UUIDに対応するnative windowへ表示し、他のactive windowへ代替しない。表示先がない、表示遷移中、mount失敗、背景移行、スワイプ閉じの場合は変更せず終了する。古い確認画面のcallbackが新しい確認を完了しないよう、表示ごとのUUIDで一度だけ完了する。

Rustは送信前に操作UUID、正確な表示元、安定した同一性の証拠、変更元と変更先、結果不明の記録を保存する。同じUUIDの変更を再送しない。元の操作結果と、明示的な読取りで確認した現在状態を分ける。変更結果が不明な表示元は、新しいUUIDでも状態確認前に変更を再送しない。ローカル記録の保存成否も確認できない場合は、無関係な変更による記録の上書きを止め、保存状態の読取りで回復する。新しい永続形式は既存の履歴やアプリ内保護を保持する。

ロック済み・結果不明のImmich表示元は、通常一覧、履歴、共有、転送、編集などから除外する。同じ内容のAppleコピーは別の表示元として維持する。キャッシュや取得中の画像、待機中のHTTP要求にも権限変更を伝え、古い要求が新しい権限を取り込んで継続しないようにする。新規コピーの保存確認は、Rustが認可した正確な保存先と処理開始時の権限世代を使う。

認証を閉じると写真情報・変更履歴・件数を隠す。端末のアプリ内保護は専用PIN認証より優先する。外部で再表示された場合は、認証した状態確認の永続化後に新しい通常一覧を取得し、同一性を確認してから通常操作へ戻す。

## 固定バージョンの契約と限界

Immich v3.2.4の[asset service](https://github.com/immich-app/immich/blob/v3.2.4/server/src/services/asset.service.ts)は、指定IDのvisibility更新後にlocked対象を全アルバムから外す。[asset repository](https://github.com/immich-app/immich/blob/v3.2.4/server/src/repositories/asset.repository.ts)の一括更新は指定されたIDだけを更新する。静止画の変更だけでLive Photoの動画もロックされたとは扱わない。ペアの保護・再表示の実サービス試験は後続で行う。

[album repository](https://github.com/immich-app/immich/blob/v3.2.4/server/src/repositories/album.repository.ts)の写真別一覧は利用者が参照できる所属に限られる。空の一覧は、全サーバー所属の解除を証明しない。visibilityの結果と、アルバム所属の「未確認」「参照できる所属なし」「参照できる所属あり」を分け、全所属解除を確認済みと誤記しない。

## 必要な検証

- 確認取消、認証期限・scene変更、確認後の同一性／revision変更で送信しない。
- 意図保存の失敗、PUT応答消失、結果保存失敗、再起動からの読取り回復と同じ操作の非再送。
- ロック→再表示→再ロックを通じた履歴と現在状態の分離、古い記録による恒久的な遮断を防ぐ。
- 結果不明・ロック済み表示元の通常操作拒否と、同じ内容のAppleコピーの独立性。
- 取得途中・待機中のHTTP・表示済み画像・共有画面の失効。新規保存先の確認は正しく許可する。
- 実Immichで所有する複数アルバムからの解除、visibility保存と再取得。Live／動画は無変更で拒否する。
- make check、Apple build、実Immich結合、固定環境のstrict VRT、最終HEADとmerge後のhosted CI。実機・iCloudは別の証拠とする。

## 検証状況

最終HEADの通し検証とhosted CIは未完了。個別に成功した検証を、変更後の全体成功に置き換えない。

| 対象 | 現在の証拠 | 最終判定 |
| --- | --- | --- |
| Rust／FFI・Swift ABI | Rust／FFI 288件（C-2回帰21件）、Swift 60件、Clippy・DTO生成が成功。追加結合fixtureのClippyも成功。 | 最終 `make check` 成功（`/tmp/suwop-visibility-check-final1.log`、終了0、Swift60件）。 |
| Apple build | 確認sheetとscene/window対応を含む最終ソースでRust全5ターゲット／XCFramework／iOS／macOSが成功。 | 最終 `make apple-build` 成功（`/tmp/suwop-visibility-apple-final1.log`、終了0）。 |
| 実Immich v3.2.4 | 結合5回目の全3件が成功。所有する2アルバムからの解除、timeline／archive再表示、所属の非自動復元、fresh scan後の通常表示、原本バイト一致、4回のPUT前の意図保存を確認。専用composeのcontainers／volumes／networkも削除確認済み。 | この範囲は成功。参照不能な全アルバム、Live／動画、実時間15分の期限は対象外。 |
| native確認sheet | 最終表示タイミング修正後のhost 5件が成功。未登録scene拒否、別key windowではなく所有windowへの表示、表示拒否後の再利用、古いcallback無効化、外部detach取消を確認。 | Simulatorの対象試験は成功。iPad複数windowの実機受入れではない。 |
| AX3操作・見た目 | 実gesture後に下段説明が固定ボタンより上へ収まることをassert。管理側が出力画像で必須説明・他コピー保持の説明・両ボタンを目視。取消時は意図保存・PUTとも0、続く確定時は変更1回。 | 対象操作・画像は成功。全UI通しは別に確認する。 |
| 全画面・UI | capture3で40画面を撮影。機能host 51件は成功。snapshot 2件のassertion失敗は新規基準未登録5枚と意図した既存4枚の差分。UI 28件すべて成功。capture自体は想定したsnapshot差分で終了2（内部compare 65）。 | strict VRT成功。40画面・host53件・UI28件が通過し、record=false／passed=true、全stage終了0。 |
| hosted CI・merge | C-2は未commit／未PR。C-1 PR #24の最終HEAD・merge後CIは全4 job成功。 | C-2の証拠にC-1のCIを流用しない。 |
| macOS共有 | `make sharing-test` の2件が成功。 | 終了0（`/tmp/suwop-visibility-sharing-final1.log`）。 |
| PhotoKit native | 最終ソースの生成JPEG fixtureで19段階が成功。製品hideはApplied、restoreはPhotosへの案内。直接unhide・hidden原本再照合・製品hide UI操作は未確認。 | 終了0・report passed=true（`/tmp/suwop-visibility-native-final1.log`、`DerivedData/PhotoKitArtifacts/20261015T024042Z-90974`）。 |
| 実機・iCloud | 今回の証拠なし。 | 未確認。 |

主要ログは `/tmp/suwop-visibility-rust-all5.log`、`/tmp/suwop-visibility-swift-all1.log`、`/tmp/suwop-visibility-clippy-live3.log`、`/tmp/suwop-visibility-apple4.log`、`/tmp/suwop-visibility-integration5.log`、`/tmp/suwop-visibility-sheet-host5.log`、`/tmp/suwop-visibility-sheet-ui7.log`。AX3スクロール後の画像は `/tmp/suwop-visibility-sheet-ui7-attachments/259AC5A5-295A-4CE6-9CD5-50A39ADB2CCF.png`。全画面撮影は `DerivedData/VRTArtifacts/20261015T020124Z-58611`。記録実行は `DerivedData/VRTArtifacts/20261015T021223Z-64473`（`/tmp/suwop-visibility-record1.log`）。

### 基準画像の判断

既存35枚は撮影前のSHA-256と一致する状態を保持し、バックアップも保存した。capture3で新規5枚すべてと、既存C-1の4枚（form／open／preview／large-text）の旧新画像を管理側が目視した。新規確認・再表示先・結果不明・未対応理由の画面、既存画面の説明訂正・再表示ボタン・変更履歴追加を意図した差分として受け入れる。残る31枚は一致している。

機能UI全28件の成功を確認し、明示的な `make vrt-record` を開始した。許可した変更は新規5枚追加と既存4枚更新だけ。残る31枚のhashを保持し、その後に別実行のstrict `make vrt` を必要とする。record1は全stage終了0・report passed=trueで完了した（host53／UI28成功）。変更範囲は新規5枚と既存4枚。対象外31枚はバックアップとbyte単位で一致する。承認したcapture3画像との比較は6枚が画素一致、form／unknown／unsupportedの3枚は最大RGB差1／2／2で、既存許容値2を超える画素は0だった。許容値は変更していない。別実行のstrict VRTは全40画面・host53／UI28件が成功し、全stage終了0。基準を記録しない比較として完了した（`/tmp/suwop-visibility-vrt-final1.log`、`DerivedData/VRTArtifacts/20261015T022543Z-72137`）。

### 修正した失敗と証拠の限界

- 初回の `make check` ではSwift ABI fixtureの原本情報GET不足とアカウントscope不一致を修正した。永続化fixtureはnativeと同じraw JSON保存・読取りへ修正した。保存失敗時にディスクが現在のbefore／desiredのどちらとも一致しない場合は、成功扱いにせず不確実状態で書込みを止める。
- 結合の初期失敗は固定検索時刻とv3.2.4アルバム応答への誤った想定を修正した。3・4回目ではバックグラウンド処理による26msのupdatedAt変化を本体が正しく拒否した。fixtureのみ、新しい操作の前に最大10秒の読取りで同じ状態が3回続くのを待つ。本体のrevision照合を緩めず、変更要求を再送しない。
- 通常Refreshが専用セッションを閉じる際、自分の通常取得contextまで失効させていた問題を、専用画面の失効処理の分離で修正した。C-2の結果不明による保護とアプリ内保護の全体失効は維持する。
- 旧UIAlertのAX3文字切れは実XCUIApplication画像でも再現したため専用sheetへ変更した。scene/window照合追加後のfocused 3・4では表示完了前のwindow照合が正常表示をキャンセルしていた。UIKitの表示完了後に照合し、それまではUIと直接callbackの両方で確定を拒否するよう修正した。
- UI6のスクロールassertionは実際にスクロールせず通っていたことを画像レビューで発見した。その結果だけを全文可読の証拠にせず、UI7で実gesture・footer境界・出力画像を再検証した。一時診断出力は除去済み。
- capture2は容量不足でUI runnerのインストールとreport作成にも失敗し、受入れに数えない。利用者の指示で使用済みSuwop Simulator 2台を削除し、マージ済みworktree 3つを復元可能にアーカイブして再開した。現在のworktree、共有ビルド出力、検証結果、使用中のSimulatorは保持した。
