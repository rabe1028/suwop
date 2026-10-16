# PIN付き動画の読み取り専用再生

2026-10-16時点の実装契約。C-1の専用セッションで、利用者が選んだ物理VIDEOの
未編集原本を同じ画面で再生する。実装・検証中であり、以下の未完了項目を含む。
通常一覧への公開、C-2の非表示／再表示、Live Photo全体の操作を許可する契約ではない。

## 対象と権限

- Rustが同じ所有者、専用grant、scene、generation、request、選択asset ID、revision、
  checksumを検証する。通常のAPIキーや保存履歴から再生権限を復元しない。
- ロックされたVIDEO自身を選ぶ。関連するLive Photoの親や動画を自動的にたどらない。
  付随動画が独立した項目として選べる場合も、その物理IDだけを対象にする。
- 閲覧権限から共有、編集、お気に入り、所属変更、コピー／移動、削除の権限を作らない。
  operation journalと関連資産の状態を変更しない。
- 原本URLとHTTPヘッダーはRustが構築する。Swiftは受け取ったGETを実行し、
  Immichのrouteを組み立てない。最終的な表示許可もRustが決定する。

## 取得と一時ファイル

Rustは原本のメタデータとセッション状態を取得し、nativeが測定した保存先volumeの
空き容量から有限の取得予算を決める。アプリの余裕として256 MiBを残し、他のleaseの
未割当予約とallocation unitを考慮する。固定の動画サイズ上限とは異なる。
サイズ情報が欠ける場合も有限予算を使い、不正なサイズ情報は欠落として扱わない。

Swiftは200・identity encodingの完全な応答だけを受け入れる。redirect、部分応答、
不正または矛盾したContent-Length、予算超過、途中切断を拒否する。原本全体をDataへ
蓄積せず、同じ一時ファイルへ書く。各書込みでも実際の空き容量を確認し、容量不足なら
停止する。取得完了後は既存のFileHashRequestを通じてRustでSHA-1・SHA-256・長さを
ストリーム計算し、受信長、期待checksum、取得後のメタデータと照合する。

各プロセスは700/600の専用UUID namespaceとowner lockを保持する。作成・掃除は
rootの非ブロッキングcoordinator lockで直列化する。別namespaceの削除には実際の
排他的owner lock取得を必要とし、lockの欠落・読取失敗を「所有者不在」と解釈しない。
symbolic linkや対象外のディレクトリは掃除しない。

## 非表示での準備と再生

検証済みの同じファイルをAVURLAssetへ渡す。Content-Typeが欠落またはoctet-streamの
場合は、再検証した正確な原本名からMIMEのヒントを作る。名前やMIME自体は権限ではない。
AVAssetの外部参照は禁止する。メタデータ検査だけでは外部参照MOVを拒否できないため、
同じ制限付きassetで非表示のフレームdecodeも行う。小さな出力は破棄し、保存・表示しない。
出力寸法の制限はcodec内部の最大メモリ使用量を保証しない。

準備後にRustが再び状態・メタデータを確認し、nativeが最新Access、epoch、正確な
window/scene所有者を同期的に確認してからplayerへ接続する。途中にawaitを挟まない。
AirPlay等の外部再生、PiP、Now Playing、動画フレーム解析によるコピー機能を有効にしない。
これらの設定はOS全体の画面収録防止やImmichの既存共有リンク失効を保証しない。

閉じる、background、所有者の付け替え、期限切れ、アカウント／状態変更では、まず
同期的に遮蔽・pause・mute・item解除を行う。取得、Rustのハッシュworker、準備、playerの
終了を待ってからファイルを削除する。新しい取得も前のteardown終了を待つ。
各native surface固有のconsumer UUIDにより、古いsurfaceの破棄が新しい再生を止めない。

## 期限と継続作業

現在の取得・ハッシュ計算・非表示準備は、開始時に捕捉した約30秒のC-1期限内に完了する
必要がある。既に許可された再生は、同じgrant等の条件を満たす正規の状態更新に従う。
ダウンロードの進捗や画面側だけの判断で取得期限を延長しない。低速回線や大きな原本が
任意の時間をかけて取得できる実装は未完了である。

後続の取得期限更新には、旧leaseが有効な間の状態→正確なメタデータ→状態の再検証、
Rustが発行する単調なlease ID、同じnative epochと前lease IDへの条件付き適用が必要。
期限切れを後から復活させず、古い完了イベントを新しいleaseで承認しない。固定した
保存容量予算も維持する。C-2の選択VIDEO変更とLive Photo複数資源の部分結果処理は別作業。

## 検証記録

この文書追加前の実装source fingerprint
`0a4c6e9daa1a5fc6ef5e0a455f109fd9b1d87947304022eca70bb0c2b5b016c6`
で`make check`が成功した。Rust/FFI 407件、Swift 65件、infra 17件と品質・DTO生成検査を
含む。実サーバー用のignored testを実行した結果ではない。

Rust-backed hash変更後のsource
`8226df4be92b18307489459b100fb2e85e208297d095c7a7dbaa4e59b474e1f5`
でmacOSの9件が成功した。実際のmotion・seek、audio状態、owner/surface変更、
MP4/MOVのMIME fallback、外部参照MOVの準備拒否を含む。
記録は`.tools/verification/private-video-mac-posthash-20261016-1-wihn6hl8/result.json`。
実行前後のsourceは一致し、終了コードは0だった。

source `bd7db1683dda2e432ead12463c20e7368b88203e58f5a5a63171b627a4018deb`
でiOS focused 30件（native 28件、通常／AX3 UI 2件）が成功した。保持したhash workerの
取消とJOIN前のファイル保持、実際のフレーム変化、Stop／Closeを含む。同じsourceで
全5 Rust target、XCFramework、iOS／macOSのApple buildが成功した。各実行の前後sourceは一致する。
記録は`.tools/verification/private-video-ios-focused-20261016-final9-9pawlafl/result.json`と
`.tools/verification/private-video-apple-full-20261016-1-h8p6h_lw/result.json`。
先行runのContent-Lengthなし再生準備timeoutは原因未特定のまま保持する。
その後の対象単独実行と30件実行の成功を、初回原因を修正した証拠にはしない。

source `3535d7a374e9547986de9efbd315bf091dc064fea2946d3cad7d7573ccd040cb`
で実Immich stable 3.2.4の13件、3.3.3の14件が成功した。直前sourceからの変更は
fixtureのlogin POST期待値を固定server契約どおり200から201へ修正した1行で、
製品取得処理は変更していない。先行3.2.4実行の12成功／1失敗も保持する。
記録は`.tools/verification/private-video-real324-20261016-2-i91ia30p/result.json`と
`.tools/verification/private-video-real333-20261016-1-0it4764i/result.json`。
実server上の認証・原本・状態変化を検証する一方、このharnessのnative prepareはmockであり、
iOS上のAV受入れとは別の証拠である。metadata欠落は明示的な注入条件である。
専用serverのcontainer／volume／networkは各実行後に削除を確認した。

同じsourceのstrict VRT初回は全体失敗だった。host 117件中3 snapshot caseが失敗し、
UI 55件はすべて成功した。47画像を取得し、7画像は動画再生の案内文追加による意図した
差分として実画像をレビュー済み。selected-observation-large-textは履歴の安定した
scroll offsetの取得に失敗し、画像未取得である。基準48画像はすべて不変、record=false。
記録は`.tools/verification/private-video-strict-20261016-1-vln147hu/result.json`と
`DerivedData/VRTArtifacts/20261015T232324Z-61716/Tests.xcresult`。
追加診断でoffsetは安定している一方、lazyな履歴行が未表示と判明した。履歴行へ
明示的にscrollToItemしてlayoutを確定してから従来の位置計算を行う修正により、
focused比較が成功した。40回の上限、連続3回の安定、対象行の可視性条件は維持している。
source `7d8e14baa8f97ef3a8dc46a7e8a7a17c99dea50b2789453f799bb7549b9334b0`
の`.tools/verification/private-video-history-candidate-20261016-2-yxdp48zy/result.json`
が成功し、取得したAX3画像は既存基準とbyte一致、通常画像も先にレビューした候補と一致した。
親レビューで実画像を再確認した。更新対象は先の7画像のみで、AX3基準は変更不要である。
明示的な`make vrt-record`は全7段階が終了コード0で、host 117件／UI 55件、計172件が
成功し、48画面を取得した。記録による画像変更のためwrapperはsource_changed／終了3であり、
通常のソース不変チェックの成功とは区別する。457件の画像以外のファイルは内容・modeとも不変。
記録時には20枚で既存比較条件内の最大2階調の描画差も出たため、取得画像を保持したうえで
それらの基準を元のbyte列に戻した。最終的な変更はレビュー済み7枚だけで候補hashと一致し、
他41枚は元の基準とbyte一致する。比較許容値は変更していない。
記録は`.tools/verification/private-video-record-20261016-1-c2o6bycw/result.json`と
`DerivedData/VRTArtifacts/20261015T235857Z-84703/Tests.xcresult`。
source `55167a91673bf912fe85e23f41a907502a218c8ab9952bb96214f435438c5914`
で最終`make check`が成功した（Rust/FFI 407件、Swift 65件、infra 17件）。
同じsourceで更新なしの`make vrt`も成功し、host 117件／UI 55件の全172件が成功、
失敗・skipは0、48画面の差分は0だった。全7段階が終了コード0で、record=false。
両実行の前後sourceは一致し、strict比較中の48基準画像のSHA-256もすべて不変だった。
記録は`.tools/verification/private-video-final-check-20261016-7-vqghndvi/result.json`と
`.tools/verification/private-video-final-strict-20261016-2-x8xdqsl6/result.json`、
`DerivedData/VRTArtifacts/20261016T003324Z-1418/Tests.xcresult`。
この結果の文書追記は上記検証後であり、製品・テスト・基準画像は変更していない。
最終HEADのhosted CIとマージは残る。
baselineは自動更新しない。
実機、物理スピーカー、iCloud、署名・配布は別の受入れである。
