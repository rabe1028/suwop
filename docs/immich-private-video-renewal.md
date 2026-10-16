# PIN付きVIDEOの取得期限更新

C-1で選択した同じ物理VIDEOの取得、Rustのハッシュ計算、非表示のAV準備を、
正規の状態更新で継続する。元のPINセッションの上限を超える権限は発行しない。
C-2の変更、通常一覧への公開、共有、Live Photoの関連資源取得を許可するものではない。
実装・受入れの記録は以下で分ける。

## Rustの許可とnativeの確認応答

Rustは状態→選択原本の正確なメタデータ→状態を再検証し、現在の取得leaseが
有効な間だけ、同じgrant、scene、generation、request、物理ID、revision、checksum、
保存先lease、固定容量予算に対する後続leaseを発行する。heartbeat開始時の取得identityを
保持するため、選択前や以前の要求で始まった検査結果を新しい取得に流用しない。
通常の静止画や変更処理の権限判定は緩めない。

後続leaseはnativeへ渡す前にRustで許可される。nativeは同じepochと旧lease ID、
不変の取得条件を確認し、旧期限が有効な間にだけ条件付きで適用する。
Rustは正確な確認応答を受けるまでPrepareや最終Accessへ進めない。
未応答の後続leaseは一つ、待機する完了イベントも一つに制限する。
旧期限後に届く応答は、nativeが旧期限前に更新済みで後続期限も有効な場合に限る。
失敗・取消・期限切れを後から復活させない。

取得と準備の結果は、処理完了時のlease IDを保持する。配信の遅れで新しいIDへ
付け直さない。連続した許可と確認応答を確認し、待機していた結果には最新の
状態・原本メタデータを再検証してから次の段階へ進む。

## 時計と容量予算

nativeは保存容量を測る時点のContinuousClockを保持する。この時点はRustの
初回ticket発行より前にある。Rustが発行時に計算した残時間をミリ秒未満切捨てで
この早い基準点へ適用し、受信時刻へ付け直さない。後続leaseもRustの新旧期限差を
切り捨てて旧native期限へ加える。これにより、配信遅延や壁時計の巻き戻しが
nativeの実行期限をRustの許可期限より先へ延ばさない。
Unix時刻を含むDTOは同一性確認に使うが、実行期限の基準を置き換えない。

初回leaseをticketとprojectionに不変値として残す。Scheduleが省略された場合や、
初回ReadよりRenewが先に届く場合も、同じ容量測定時点と初回期限からだけ初期化する。
nativeの監視タイマーはcontroller作成・更新時に直接始動し、Schedule配信だけに依存しない。
古いlease用のタイマーは、後続leaseを停止できない。

更新は同じ一時ファイルを使い、容量予約、最大受信長、既受信byte数をリセットしない。
各書込みは有効な取得leaseと固定予算を確認した区間内で行う。
取得を最初からやり直したり、原本全体をDataへ集めたりしない。

## 取消と公開後の再生

取消では同期的にplayerを遮蔽し、stream、Rustのhash worker、非表示のAV準備を
停止して終了を待ってからファイルを解放する。AV準備の取消callback登録直前に
期限切れになった場合も、既に作ったTaskを所有し、終了まで待つ。

Rustが最終Accessを公開しても、それだけではnativeの再生を許可しない。
nativeは取得controllerのlock内で、期限内・未終了・取得処理の取消callbackなしを確認して
公開済みへ移行する。同じlockで期限切れと競合させ、期限切れが先なら該当要求を遮蔽する。
成功したstageにだけ明示的な公開receiptを残し、取得用controllerとタイマーを終了する。
asset取得・playerへのattachにもこのreceiptを要求し、controller不在を公開成功とみなさない。
承認したファイル・asset・playerは別のC-1表示leaseが所有し、同じ原本への正規の
heartbeat検証を続ける。公開後の古い取得期限イベントで有効な再生を停止しない。
閉じる・background・所有者変更・セッション失効では従来どおり遮蔽と終了待ちを行う。

## 検証記録

最終の対象Rust検証は22件成功。全target・全featureのClippyも成功した。
両runのsourceは`0c8696ab56bf5e2b99a8e5bb7ca585ea52f1758065dc0afa66574dc0fa938fb2`で前後一致。
記録は`.tools/verification/video-renewal-focused-20261016-4-t5jvddxm/result.json`と
`.tools/verification/video-renewal-clippy-20261016-3-cjl72k6x/result.json`。
後者は実サーバーharnessのcompileを含むが、サーバーへの結合実行ではない。

nativeの初回診断buildはSwiftのSendable制約と未使用戻り値でcompileに失敗し、
テスト本体には到達しなかった。型制約を明示した修正後の対象iOS buildは成功した。
source `ae8dff9bb849e409f3ea0807e8f149fd39549bdaaf2e91158b06c5400069d51c`、
`.tools/verification/video-renewal-ios-build-20261016-2-5rvjksln/result.json`、前後一致。
これは対象Simulatorのbuildであり、全Apple build、実機、iCloudの証拠ではない。

以下の全体検証後に公開時の競合が見つかったため、修正後の受入れと最終HEADのhosted CI・マージは未完了。

取得leaseの更新は、初回ファイル作成時に必要な保存容量測定の10秒の鮮度を延長しない。
初回Readを20秒のheartbeat後まで保留すれば、取得leaseの更新が成功しても、古い容量測定で
ファイル作成や原本送信を開始してはならない。初回ReadよりRenewが先に届く成功経路は、
容量測定も有効な間に実際の状態検証と条件付き更新が完了した場合に限る。

初回対象native runは44件中43件成功・1件失敗で、全体は未通過。
`.tools/verification/video-renewal-native-20261016-1-s6ivlyk7/result.json`、
source `ae8dff9bb849e409f3ea0807e8f149fd39549bdaaf2e91158b06c5400069d51c`前後一致。
新規14件のうち13件、既存host28件、通常／AX3 UI2件が成功した。
実際の低速原本streamは約49秒にまたがる2回の正規更新を経て、decodeした画素の変化と
取得期限終了後の再生継続まで70.661秒のケースで確認した。hash32.168秒、非表示準備
32.116秒の保持ケースも成功。初回Readを20秒遅延させたケースは保存容量測定の
10秒の有効期間と成功期待が整合せず、失敗を保持して拒否・成功の別ケースへ分けた。

修正した対象2件はsource
`5a71620108d16dfe09700f9620df2b9beadad4e495f126b51b419181187c1fd2`で成功、前後一致。
`.tools/verification/video-renewal-quote-ordering-20261016-3-j9ttnrkl/result.json`、
実際のCheckイベントを早く発行する成功ケース0.453秒と、20秒後の更新後でも古い容量測定を
拒否するケース20.142秒で確認した。製品の期限・予算・APIをテストのために緩めていない。
途中の診断run 2はfixtureの非optionalなlease IDにoptional bindingを使ったcompile失敗で、
runtimeには到達していない。新規ケースは15件になったが、現sourceの全45件一括成功とは
主張しない。先行43件と修正後2件の結果を区別し、全体VRTで改めて検証する。
全48枚の基準画像はバイト単位で不変。通常／AX3の実再生画像は管理側も確認した。
この文書追加は検証後の証拠整理であり、上記source fingerprintには含まれない。


### 全体検証と公開時の競合レビュー

source `3c3f94ab1333dc0ff03635bdc52d2e5420d56cf398c034514e2a398fe783b168`では、
全体check（Rust/FFI 420、Swift 65、infra 17）、全5 Rust targetとXCFrameworkを含む
Apple build、Mac native 9件が成功し、各runのsourceは前後一致した。
記録は`.tools/verification/`内の以下の`result.json`に残す。

- `video-renewal-check-20261016-1-siee5yb1`
- `video-renewal-apple-full-20261016-1-1018ndea`
- `video-renewal-mac-native-20261016-1-odqsabhk`
- `video-renewal-real324-20261016-1-1hwqmq7e`
- `video-renewal-real333-20261016-1-4d_d1alj`

実Immichは3.2.4で13件、3.3.3で14件が成功。同じ実セッションで後続lease 2、3の
状態・選択メタデータ・原本取得とjournal不変を確認した。native CASとAV準備はこの
harnessではmockであり、nativeの時間競合を証明しない。所有する検証用stackは終了・削除した。

strict VRT `video-renewal-strict-20261016-1-xsrciv9b`はhost 132件と48画面比較差分0まで
進んだが、UI実行中のレビューで取得期限と最終公開の競合を発見したため、所有する
xcodebuildへSIGINTを送り停止した。wrapperは618.06秒、exit 2、source前後一致。
全187件の成功ではなく、記録更新なしの中断runとして保持する。

nativeのContinuousClock期限はRustの期限より早く到来し得る。期限切れ処理が先に
controllerを終了しても、遅れて届いたRust Accessがその終了証拠を消して再表示できる
経路があった。修正には同じlock内での期限切れと公開の排他的な引継ぎが必要で、
単に有効性を検査してからcontrollerを削除するだけでは競合が残る。期限切れが先なら
該当要求を同期的に遮蔽し、公開が先なら表示leaseによる再生を維持する。
この時点では修正と公開直前の遅延を使う回帰検証は未実施だった。上記成功結果を修正後の証明に流用しない。


### 公開時競合の対象回帰検証

修正source `f9aea174c68751c975c51ab3a553a113aab92fd53c6ecb485295be9f67b72ec1`で
対象9件が成功した。記録は
`.tools/verification/video-renewal-publication-20261016-2-khx8pv4g/result.json`、
110.95秒、exit 0、source前後一致。
controllerの勝敗・旧callback・固定予算を確認する7件に加え、実際のInspect結果を5秒遅延し、
準備完了と期限切れ通知を別々に保留したケースが成功した。native期限切れ後もRust側の
期限内であることを確認して本物の準備結果を届け、遅いAccessと再通知を拒否し、
原本ファイルの解放、新しい要求の再生、古い期限切れ通知の無効化まで確認した。
実低速streamの2回更新ケースでも、公開後の古いcontrollerの期限切れと再通知が再生を
停止しないことを追加検証した。これは対象9件の証拠であり、修正後の全体strict VRTではない。

最初の対象runは新しいテストファイルのproject登録不足に気づいて中断し、exit 73、
62.66秒、source前後一致で保存した。XcodeGenで登録を生成してSourcesへの所属を確認し、
所有Simulatorのprofile検証成功後に上記9件を実行した。未登録ケースの省略を成功と扱っていない。


### main統合後の最終ローカル検証（2026-10-16）

PR #35と検索基盤を統合したsource
`be0f4293f6fa378f7ef43b00cb887c93e966b4cbe08559b892d7b68b2d6c6ad0`で、以下が成功した。
各runのsourceは前後一致し、過去の対象検証や中断runとは区別する。

- DTO生成：差分なし。`video-renewal-main9382-generate-20261016-1-mmdf_azv`。
- 全体check：Rust/FFI451、Swift70、infra24件。`video-renewal-main9382-check-20261016-1-oe6_c11d`。
- 実Immich 3.2.4：13件、3.3.3：14件。
  `video-renewal-main9382-real324-20261016-1-vqic2ib3`／
  `video-renewal-main9382-real333-20261016-1-ae0seqs7`。
  後続lease 2・3、journal不変を確認。native CAS／AV準備はこのharnessではmock。
- 全Apple build：全5 Rust target、XCFramework、iOS・macOSアプリ成功、7658.35秒。
  `video-renewal-main-apple-20261016-1-kv8spry7`。
- Mac native：9件、失敗0、54.86秒。`video-renewal-main-mac-20261016-1-u0dl4zb2`。
- strict VRT：host147／UI57の全204件、失敗0、2536.4秒。
  `video-renewal-main-strict-20261016-1-_8kbfyql`。
  全50画面差分0、全7段階exit 0、record=false、全50基準画像のSHA256が前後一致。

上記run名の完全な記録は各`.tools/verification/<run>/result.json`と`output.log`に保存した。
VRT成果物は`DerivedData/VRTArtifacts/20261016T083621Z-21567/`のreportとTests.xcresult。
公開競合25.686秒、取消30.301秒、順序6件101.713秒、遅延hash／準備／実streamの3件
134.950秒（stream70.685秒）を全体run内で通過した。
通常動画UI37.147秒／AX3動画UI46.330秒も成功。管理側がexportした実再生フレーム
10.33秒／12.16秒と、説明・停止・閉じる操作の表示を確認した。
Xcodeのテスト後診断収集にsimctl code72の警告があるが、テスト成功と区別して保持し、
所有Simulatorのshutdown成功と最終Shutdown状態を別途確認した。

検証後、未公開ブランチの基点をPR #35のsquash後main `14e1bcc`へ揃えた。
旧統合HEAD `9382a93`とmainのtreeが同一であることを確認し、589ファイル・index tree・
source fingerprintを前後一致で保持した。保全patch・未追跡ファイル・Git状態と旧HEAD参照を残す。
この記録追記は上記ソース検証後の文書変更である。
最終コミットのhosted CI・レビュー・マージは未完了。実機／iCloud受入れではない。
