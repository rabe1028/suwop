# Immichの選択した動画のアーカイブ

通常のAPIキーで、選択したVIDEOの表示先をTimelineとArchiveの間で変更する増分。
関連するLive Photo全体の可視性変更やPIN操作とは別に扱う。

## 権限と対象

Rustの型付き通常認可だけがVIDEOを許可する。PIN認可のVIDEO・Live対象は従来どおり拒否する。
一つの完全な動画原本、stackなし、オンライン・非ゴミ箱、現在のTimeline/Archive状態を必要とする。
変更前のAPI応答でowner・key・checksum・revisionを確認し、livePhotoVideoIdの明示nullを要求する。
項目の欠落やリンク・stackがある応答は拒否する。カタログの操作候補は最終的な変更許可ではない。

VIDEO自身のforward linkがnullでも、逆向きの関連写真が存在しないとは限らない。
選択した動画が関連写真の一部でも、変更するのはその動画の表示先だけである。
関連写真をロック解除した、Live Photo全体を再表示した、という意味にはしない。
確認画面は選択した項目と関連写真の表示先が別であることを説明する。

## 記録と復旧

既存IMAGEのwitness digestはbyte互換を保ち、VIDEOには別のタグを使う。
確認前後の型・原本・revision・可視性の相違は変更を止める。
通常操作とPIN操作の記録kindを分離し、通常操作からPIN一覧を生成しない。
再照合は記録kindに従い、異なるkindや未確定Unknownの制限を解除しない。
永続化したUnknownを一度だけ送信し、応答消失・再起動後に再送しない。

## 検証の状況

`/tmp/suwop-video-archive-check-20261015-4.log` でmake checkが成功した。
Rust/FFI323件・Swift65件が成功し、実サーバー用7件は通常テストではignoreとなる。
通常VIDEO、確認中の型変更、明示nullと不明リンクの区別、旧IMAGE digest、
PINの直接イベント拒否、混在kind、Unknownの再起動後の書込み停止を含む。
前のcheck1〜3はテストコードのlint違反で失敗し、抑制せず修正した。

実Immich v3.2.4の結合は7件すべて成功した
（`/tmp/suwop-video-archive-integration-20261015-1.log`）。
PIN未設定のVIDEO往復で原本・2アルバムを保持し、別fixtureではPをロックしたまま
関連するMだけを通常APIキーで往復変更した。製品操作の認証要求0・PUT2回を確認し、
製品操作終了後のfixture専用PIN検証でPのロック・P2の表示先・関連リンク・全5原本を確認した。
専用Docker projectのcontainer・volume・networkだけを削除し、他サービスの稼働を確認した
（`/tmp/suwop-video-archive-cleanup-20261015-1.log`）。

Appleビルド、native UI/VRT、hosted CIは個別に結果を確認する。
実機・iCloud・Apple由来のLive Photo受入れの完了を意味しない。

## Native確認と大文字表示

確認文言は選択した項目と関連写真を区別し、タイムラインへ戻す場合は他のImmichアプリにも
表示される場合があることを説明する。同じ文言をiOSとmacOSで使う。
初回nativeソースのmake check、全5 Rustターゲット・XCFramework・iOS/macOSビルド、
macOS確認・共有14件は成功した（`/tmp/suwop-video-native-check1-20261015.log`、
`/tmp/suwop-video-native-apple1-20261015.log`、`/tmp/suwop-video-native-sharing1-20261015.log`）。

初回functional検証はhost13件と通常サイズのVIDEO往復が成功した一方、AX3で失敗した。
最初はnativeメニューが下端までスクロールされた状態で上部項目を探すテスト手順の問題で、
実際にメニューをスクロールして表示させるよう修正した。
その後、動画の再生を含む横一列のボタンが画面幅を超え、ビューアの閉じるボタンが
x=-81.7へ押し出されていた製品不具合を検出した。記録は
`/tmp/suwop-video-native-functional1-20261015.log`、
`/tmp/suwop-video-native-ax3-ui2-20261015.log` と各xcresultに保持する。

accessibilityサイズだけ操作を折り返すgridと別の前後移動行に分け、既存の操作内容を再利用する。
日付は中央揃えで折り返す。通常サイズは元の操作順・間隔を維持する。
修正後make checkは成功した（`/tmp/suwop-video-responsive-check2-20261015.log`）。
修正後の全Appleビルドも成功した（`/tmp/suwop-video-responsive-apple2-20261015.log`）。
AX3の実UI往復は成功し、全操作の画面内配置と到達可能性、キャンセル時の書込み0、
更新後のタイムライン確認文の末尾、固定ボタン、認証要求0・PUT2回を確認した
（`/tmp/suwop-video-responsive-ax3-ui4-20261015.log` とxcresult）。

45画像の候補比較では43枚が一致し、変更した確認文の通常・大文字2枚だけに差分があった
（`/tmp/suwop-video-candidates1-20261015.log`）。候補比較時点では全45基準画像を変更していない。
通常ビューアも一致した。親レビューで2候補とAX3のスクロール後の説明末尾を目視確認し、
意図した2枚のみ基準更新を承認し、更新した。残り43枚はbyte一致を維持する
（`/tmp/suwop-video-reviewed-baseline-record-20261015.json`）。
先行アーカイブの保存不確定時の操作可否修正（08230c4）を取り込んだ。
追加テストの競合は両方の回帰を残して解消し、対象15件が成功した
（`/tmp/suwop-video-archive-rebased-focused-20261015-1.log`）。
取り込み前の388ファイルのバックアップと照合し、差異は先行修正のRust本体・テスト・
説明文の3ファイルだけだった。Swiftと承認済み基準画像は保持した。
このbaseで最終make checkと全体strict VRTを確認する。

このbaseのmake checkは成功した（`/tmp/suwop-video-rebased-final-check1-20261015.log`）。
全体strict VRTは失敗した（`/tmp/suwop-video-rebased-final-strict-vrt2-20261015.log`、
`DerivedData/VRTArtifacts/20261015T105534Z-87751/report.json`）。host77件とUI36件は成功し、
45画像一致・差分0・基準hash不変だったが、通常サイズのVIDEO往復UI1件で8つの
画面内配置検査が失敗した。通常の横一列に再生ボタンが加わると画面幅を超え、
閉じる・情報・前後移動が端へ押し出される実画面を確認した。
AX3専用の折り返しは通過している。文字を縮小したり検査を緩めたりせず、
通常サイズでも実幅に収まらない場合の折り返しを追加して再検証する。

通常サイズの修正は`ViewThatFits`で元の横一列が収まるか判断し、収まらない場合だけ
既存の折り返し操作と前後移動行を使う。動画用の`viewer-video`画像比較ケースを追加する。
候補画像の採用は目視確認後とし、既存の静止画ビューアの画像は一致を確認する。
保存状態の共通判定（aca1736）も取り込み、対象16件が成功した
（`/tmp/suwop-video-archive-durable-rebased-focused-20261015-1.log`）。
388ファイルのバックアップとの差異は先行修正の5ファイルだけで、動画側のSwift・
テスト・画像候補設定を保持した。修正後の実画面と全体VRTは引き続き検証する。

配置修正後の対象UIは通常VIDEO往復とAX3往復の両方が成功した
（`/tmp/suwop-video-fit-ui1-20261015.log` とxcresult）。画面内配置の検査は緩めていない。
この実行は新しいSwift配置と先行fc596ad時点のSimulator Rustライブラリの組み合わせであり、
配置修正の証拠に限定する。最新Rustを含む受入れは、再ビルド後の最終検証で確認する。

最新baseの`make check`と全Appleビルドは成功した
（`/tmp/suwop-video-fit-current-check1-20261015.log`、
`/tmp/suwop-video-fit-current-apple1-20261015.log`）。再ビルド後の候補比較では
46枚すべてを取得し、既存45枚は一致、新規`viewer-video`の基準未登録だけで終了した
（`/tmp/suwop-video-fit-candidates3-20261015.log`）。親レビューで動画ビューアの
ヘッダー・5操作・前後移動が画面内に収まることを目視確認し、新規1枚だけを採用した。
既存45枚のhash不変と候補・基準のbyte一致を独立照合した
（`/tmp/suwop-video-viewer-baseline-record-20261015.json`）。
先行アーカイブの複数scene所有権修正を取り込んだ後、全体strict VRTを実行する。
この候補比較を全体strict VRT成功とは扱わない。

Native VIDEO fixtureは実RustのVIDEOメタデータと通常認可を使用するが、原本動画の実バイトや
再生の受入れ証拠ではない。原本バイト・関連写真保持の証拠は実Immich結合で別に記録する。

先行アーカイブの明示的scene所有権と履歴再表示修正（50984e5）を含む
Live graph base `6afd74195fb8622d096db8ca0e9e661a6b426a45`へ取り込んだ。
取り込み前の389ファイルをtarとSHA256一覧に保持し、元の未コミット差分もstashに残した。
先行アーカイブの新しい取消し・再起動・再接続回帰とVIDEO回帰を両方保持して競合を解消した。
取り込み前と391ファイルを照合し、変更は先行修正とこの記録の14ファイル、追加は先行修正の
UI fixture/test 2ファイルだけだった。それ以外の内容と承認済み動画基準3枚はbyte一致を保持した。
この取り込み後のcheck・Apple・全体strict VRTは改めて確認する。

追加のkey単位画像無効化とbusyメニュー修正（4cd7577）を含むLive graph base
`bcca7bece6a058d52a1f124bcb8a9e3e589d0878`へ再度取り込んだ。
取り込み前391ファイルをtar・SHA256一覧に保存し、未コミット差分のstashも保持した。
唯一の競合はvisibility回帰テストで、先行ファイル全体をそのまま保持してVIDEOの
PIN拒否回帰を残した。新しいscopedメニューと動画ビューアの折返しレイアウトを両方保持した。
この記録追記前の394ファイル照合では変更6・追加3・削除0で、すべて先行修正に一致した。
承認済み動画基準3枚と、それ以外の既存ファイルはbyte一致した。
このbaseのcheck・Apple・全体strict VRTは未実行であり、先行PRの検証完了後に実行する。

この統合sourceでmake checkはRust/FFI334件・Swift65件成功（実Immich用7件は別実行）、
全5 Rust Appleターゲット・XCFramework・iOS/macOSビルドも成功した
（`/tmp/suwop-video-integrated-check3-20261015.log`、
`/tmp/suwop-video-integrated-apple3-20261015.log`）。
全体strict VRTはnative77件・UI41件が成功し、46画面の画像差分は0だった
（`/tmp/suwop-video-integrated-strict3-20261015.log`、
`DerivedData/VRTArtifacts/20261015T130659Z-34628/report.json`）。
record=false、全7 stageが終了0、46枚の基準hash不変を独立照合した。
先行PRのhosted CIで発生した保護メニュー操作失敗は別に調査・再現性確認中であり、
このローカル成功をCI成功の代用にはしない。

同じ統合sourceの実Immich結合7件も20.02秒で成功した
（`/tmp/suwop-video-archive-integration-20261015-2.log`）。
PIN未設定の動画往復、親Pがlockedでも選択動画Mだけを通常権限で変更するケース、
既存の5契約シナリオを実行した。専用container・volume・networkの削除と
無関係サービスの保持を確認した（`/tmp/suwop-video-archive-cleanup-20261015-2.log`）。
