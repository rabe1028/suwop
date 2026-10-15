# Photos parity 実装・受入れロードマップ

2026-10-14。監査基準は main `eb47377`（PR #19）。到達条件は
[photos-parity.md](photos-parity.md)、実機受入れは
[verification.md](verification.md)を参照する。この文書は残作業の管理用であり、
実装・検証・マージの完了を代わりに宣言しない。

## 監査基準 main eb47377 時点の証拠

- PR #19 の [CI run 38331346444](https://github.com/rabe1028/suwop/actions/runs/38331346444)
  は管理側が遠隔で確認し、core / immich-integration / apple / vrt の全4 jobが通過。
- 専用Simulatorの生成JPEGでは、製品core・Appleアダプターによる保存、7回のプロセス起動、
  保存応答消失後の読取り確認、貼り付け、キャンセル、原本への復元を検証済み。
  原本署名・日時・位置・お気に入りと、現在画像の寸法・色を確認する。
  [対象と制約](native-photokit.md)を超えて実機・iCloud・RAWの証拠にしない。
- VRTは固定iPhone環境の23画面。操作テストは露出スライダー、取り消し・やり直し、
  セピア、ドラフトの返却、キャンセル、編集コピー項目の選択を含む。
- PhotoKitテストホストは編集ドラフトと確認への回答を注入する。製品の編集画面から
  実保存までの一連の操作、全調整、切り抜きのジェスチャー、実Photosでの見た目は別途受入れが必要。
- 実機、iPad / Macの操作、iCloud、署名・配布は未確認。古い文書内のローカル成果物の
  パスは監査checkoutでは再閲覧できておらず、記録済み証拠として扱う。

## 管理方法と順序

各IDで、実装、local checks、最終HEADのhosted CI、画面操作、native/API保存結果、
実機/iCloud受入れを別々に記録する。実装済みでも未確認の欄を完了にしない。
以下の状態は `eb47377` の監査時点を基準とし、PP-01とPP-02は以下の進捗を反映する。

原則はPP-01から順に小さなPRで進める。PP-15の証拠は各PRで蓄積し、
PP-16で対応する実機・配布の条件を閉じる。依存はPP-03→PP-04、PP-09→PP-10。
PP-08のImmich幾何保存は色編集の保存方針と独立して進められる。
所要時間の見積りは置かない。

| ID | 監査状態と実装範囲 | 完了に必要な証拠 |
| --- | --- | --- |
| PP-01 Apple通常削除・復元案内 | **PR #20 merge 済み（main `8351ea7`、最終HEAD／merge後 hosted CI 全4 job成功）**。Moveと独立した確認・原本照合・永続意図・PhotoKit応答・可視性検査とApple Photosでの復元案内。Rust202/Swift50、VRT26/UI5、生成JPEGのNative12段階を通過。 | 単独/複数、確認取消、権限/ID変更、応答消失/再起動、結果不明時の書込み停止と同じ原本の転送保護。公開復元APIの制約を表示。実PhotoKit保存と実機/iCloudは別記録。 |
| PP-02 非表示・再表示 | **A-1 PR #21、A-2 PR #22はmerge済み（A-2 main `f845a6f`）。BはPR #23としてmerge済み（main `4283846`）、最終HEAD／merge後CI全4 job成功（merge後の結合jobは取得制限後の再実行で成功）**。[Apple可視性](apple-visibility.md)／[アプリ内保護](app-protected-photos.md)。A-2最終HEAD `9b78207` とmerge後mainのCI全4 jobが成功。Bはschema5の表示元別保護、端末認証、scene限定閲覧、再ロック、結果不明時の書込み停止・読取り回復を実装。切断済みアカウントの匿名記録・認証後のローカル保護解除のレビュー修正後にRust/FFI252／Swift55、全Apple build、Immich結合、strict VRT31画面／host25／UI15、PhotoKit19が成功。既存28基準は保持し、新規3枚だけ追加。PhotoKit製品hideはApplied、restoreはPhotos handoffで、直接再表示・hidden原本readbackは未確認。[C-1のImmich session／PIN付き閲覧](immich-locked-session.md) は実装・ローカル検証済み。Rust/FFI262／Swift57、全Apple build、実Immich結合2件、strict VRT35画面／Host33／UI20が成功。B/Cの実プレビュー表示と古い画像の破棄境界も回帰修正済み。C-1はPR #24でmain `dfd1eb2`へmerge済み。最終HEAD `dde851e`のレビュー修正後checkはRust/FFI266・Swift57で成功し、hosted CI全4 jobも成功。merge後CIも全4 job成功（成果物アップロードtimeout後の再実行で成功）。C-2のサーバーvisibility変更は別worktreeで実装し、[C-2検証記録](immich-visibility.md)の最終ローカル検証が成功。Rust/FFI288・Swift60、全Apple build、実Immich結合3件、共有2件、strict VRT40画面／host53／UI28、PhotoKit19段階が通過した。基準画像は新規5枚・既存4枚だけ変更し、残る31枚を保持した。初期HEADのhosted CIは全4 job成功。レビューでstack操作候補を修正し、修正後check（Rust291／Swift62）、全Apple build、実Immich結合3件、strict VRT40画面／host54／UI30も成功。修正後HEAD `7850d9b` のhosted CI全4 jobも成功した。追加レビューで同一認証内の古い一覧を修正し、保存前失敗からの一覧更新と厳密な保存読戻し比較を追加した。修正後のRust300／Swift62・実Immich結合3件・focused host7／UI4件は成功。最終Apple buildも全5ターゲット・iOS/macOS成功。nativeの古い更新待機とVRTの文字サイズ継承も修正し、最終strict VRT40画面／host62／UI33が成功。更新基準6枚・対象外34枚保持。新HEADのCI・mergeは未完了。最初は関連動画・stackのない静止画を対象とし、Live Photo・動画は別途扱う。 | C-2の実装・検証。Cはsession／PIN期限／再ロック・全アルバム所属への影響を別に検証する。実Face ID／Touch ID／パスコード、複数ウィンドウの手動操作、実機／iCloudは未確認。 |
| PP-03 外部ファイル取り込み | 未実装。転送用AppleImport effectを完了証拠にしない。native picker/読取りとRustの構成検証・保存先選択・永続化を追加する。 | JPEG/HEIC/PNG/動画、RAW+JPEG/Live関連ファイル。元バイト・名前・日時・位置、欠落した組の拒否、キャンセル、送信前保存失敗、応答消失/再起動、PhotoKit/実Immichの保存結果。 |
| PP-04 複製 | 未実装。原本の複製と現在の編集済み見た目の複製を区別し、新しい保存先IDを確認する。PP-03に依存。 | 元写真/履歴を保持、新ID・バイト・メタデータ、RAW/Liveの組、再起動。Immichのchecksum重複排除を先に確認し、既存IDが返ることを複製成功としない。 |
| PP-05 現在の内容の共有・書き出し・片付け | 単独の現在静止画と単独/複数の原本共有は実装済み。現在の内容の複数選択、動画/Live、位置情報を除去する書き出し、強制終了後の回収は未実装。 | 表示元/原本の選択、受信先で開いた実結果、寸法・向き・色・メタデータ、組の完全性、キャンセル、iPad/Mac共有、強制終了後の安全な片付け。原本共有では元バイトを保持。 |
| PP-06 メタデータの残操作 | 保存先ごとの日時/座標、Apple位置削除は実装済み。説明、任意タイムゾーン、地図/地名、取り消し/元の値への復元は未実装。 | 製品画面から変更→保存→再取得/再起動。日時調整後のコピー、保存先間の差、DST/不正値、説明と検索、原本EXIFとライブラリ位置の区別。Apple説明は下記API制約を明示。 |
| PP-07 アルバム・順序・フォルダー | 所有する通常アルバムの基本操作は実装済み。Appleのアルバム削除のnative受入れ、順序、フォルダー、共有/スマートアルバムは残る。 | collection削除後に写真保持、並び替え、階層の作成/移動/削除と循環防止、共有先の操作権限、scope/権限再確認、再起動、実Immich API。扱えない操作は能力と代替を明示。 |
| PP-08 Immichの編集保存・復元 | 編集後プレビューと対応する幾何系列からのPNG共有は実装済み。編集保存/復元は未実装。crop/rotate/mirrorの保存をRustへ追加する。 | 製品エディターの見た目、保存/再編集/復元、実APIの順序付き系列、原本署名/メタデータ保持、応答消失の記録と読取り、並行編集。生成jobのenqueueだけで最新プレビューを確認済みにしない。 |
| PP-09 高解像度SDR・透過 | 編集入力/出力は16MPまで。Apple編集保存は透過を拒否する。上限変更に先立って描画/符号化のメモリ方式を変更する。 | 24/48MP/パノラマのピークメモリ、切り抜き/回転/プレビュー/保存/取消、奇数寸法、P3/透過保持、実PhotoKit保存。現在のApple画像のバイトコピーと原本復元には編集の上限を適用しない。 |
| PP-10 HDR・RAW・他アプリ編集 | HDR編集は拒否。RAW/既存他アプリ編集の受入れは未完了であり、全RAW対応済みとしない。PP-09の描画方式に依存。 | gain map/高bit深度/色の保持、SDRへの無断変換なし。RAW+JPEGの全原本、既存編集を土台にした保存/再編集/復元、原本署名、端末メモリ、実機/iCloud。 |
| PP-11 静止画編集の残調整 | crop/90度回転/反転、露出/明るさ/コントラスト/彩度、3フィルター、履歴と選択式コピー/貼り付けは実装済み。Photosの残調整/フィルター/自動補正は残る。 | 各追加調整の見た目と操作、取り消し/やり直し/リセット、プレビューと保存結果の一致、再編集、選択式一括貼り付け、native取消。傾き/遠近補正、フィルター強度、原本比較の具体的な追加は到達条件の具体化提案として扱う。 |
| PP-12 動画編集・現在の再生 | 原本再生は実装済み。トリムと編集後の再生/書き出しは未実装。PhotoKitの動画編集出力へつなぐ。 | timelineのnative操作、音声、保存後の長さ/track/向き、元動画保持、現在の再生/共有、取得/符号化取消、応答消失/再起動、長尺/HDR。速度変更・追加音声編集は追加提案。 |
| PP-13 Live Photo編集・現在の共有 | 原本ペアの復元/再生は実装済み。編集と現在のLive共有は未実装。公開native編集APIで関連ファイルを扱う。 | 実撮影ペア、静止画/動画の編集一致、関連ID、音声、再生/共有、原本ペアの署名/復元、取消/再起動/iCloud。key photo/trim/loop/bounceの具体範囲は公開APIを個別確認する。 |
| PP-14 場所・人物・分類・思い出・重複整理 | 未実装。座標による場所、Immichの対応する検索/分類、アプリ自身の整理と重複レビューへ分解する。 | 実データの検索/分類、空/誤分類、scope別ID、再照合後の選択、複数原本の多重度。既存catalogの統合を重複のmerge操作の証拠にしない。削除を伴う整理では保存すべき編集/メタデータ/所属を明示。 |
| PP-15 権限・回復・性能・アクセシビリティ | core/cancellation/一部大文字VRTは実装済み。広いnative受入れ・性能測定は未完了。fixtureと測定手順を整備し、各PRで拡張する。 | 拒否/限定/フルと途中変更、断線/アカウント変更/iCloud-only、process/OS再起動、検索/並べ替え/統合分割後の選択、VoiceOver/大文字/keyboard/回転、iPhone/iPad/Mac。大量libraryと一括編集の時間/ピークメモリを記録し、10k/100k規模は測定ケースの提案とする。 |
| PP-16 署名・配布・実機・iCloud | 使用許可文言/bundle ID/Mac sandbox設定は存在。署名/配布/実機/iCloud受入れは未確認。 | 実機インストール/更新と状態移行、小さなテストlibraryで両方向Copy、RAW/Live/burst/iCloud、正常Moveの転送元のみ削除、他端末の同期。選んだ配布方式の署名/Mac notarization等。テスト端末・account・配布資格の入手を別に記録。 |

## APIの制約、代替、判断が必要になる地点

PP-02A-1 の P2 重複指紋・move理由匿名化と metadata UI の有限時間終了待ち修正は、`make check` Rust/FFI218／Swift52、全Apple build、strict VRT26画面／host unit15／UI7を通過した。既存基準画像の追加変更はない。前HEAD `03331a9` の hosted CIはcore／Immich integration／apple成功、metadata UI assertionによりVRT失敗。P2最終HEAD `51dd7df` の [CI run 38572443227](https://github.com/rabe1028/suwop/actions/runs/38572443227) は全4 job成功し、PR #21はmain `b12db01` へmerge済み。[merge後CI run 38574669375](https://github.com/rabe1028/suwop/actions/runs/38574669375) は全4 job成功。A-2統合sourceの最終gateは別に確認する。履歴は[検証](verification.md)に保持する。

- Rust/Cruxが操作・検証・永続化とImmich APIを所有し、SwiftはUIとnative I/Oを実行する。
  assetの同一性はprovider / scope / physical ID。checksumグループの別コピーから可視性や編集を借りない。
- Appleの`PHAssetChangeRequest.isHidden`は公開SDKで書込み可能。ただしiOS 16以降は、
  非表示アルバムの認証設定が有効（既定）の場合、`includeHiddenAssets = true`でも
  非表示assetを取得できない。[AppleのisHidden契約](https://developer.apple.com/documentation/photos/phasset/ishidden?changes=l_4&language=objc)を参照。
  取得できるassetだけを直接再表示し、取得できない場合はPhotosでの認証・再表示と更新を案内する。
  非表示後の通常一覧からの消失だけでは、権限変更と区別した保存結果の証拠にならない。
- PhotosPickerで利用者が非表示写真を選ぶことは可能。photoLibraryを指定した構成なら
  local IDを取得できるが、ID/提供データがあることはPHAssetの取得・変更権限の証拠ではない。
  [itemIdentifier](https://developer.apple.com/documentation/photosui/photospickeritem/itemidentifier)、
  [pickerの公式sample](https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios)、
  [PhotoKitの権限](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)に従い、
  picker選択後も実fetchと権限・変更能力を確認する。コピーしたデータを元assetの再表示と呼ばない。
- アプリ内の保護された非表示は別の代替として明示する。認証前に画像/名前/件数を自動表示せず、
  閉じる・background・再起動で閲覧許可と画像cacheを解除する。Apple/Immich側の状態変更ではなく、
  Photosのロックと同じ保護を実現したとも表示しない。
- Appleのフォルダー変更と写真/動画/Live編集には公開APIがある。
  [collection list](https://developer.apple.com/documentation/photos/phcollectionlistchangerequest)、
  [content editing output](https://developer.apple.com/documentation/photos/phcontenteditingoutput)を参照。
  未実装であることを外部環境の制約に置き換えない。
- Immich v3.2.4の編集系列はcrop / rotate / mirrorのみ。
  serverは動画・Live・パノラマの編集を拒否する。
  [固定版DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/editing.dto.ts)、
  [固定版service](https://github.com/immich-app/immich/blob/v3.2.4/server/src/services/asset.service.ts)で確認。
  色/動画/Liveの編集をImmichで扱うには、アプリ独自の編集レシピか別の編集済みassetなどが必要。
  利用者は編集済みの別コピーを Immich に保存し、原本を保持する方式を選択済み。[保存先の方針の決定](#保存先の方針の決定2026-10-14)に従って PP-08 / PP-12 / PP-13 で実装する。
  対応する幾何保存やread-only書き出しは先に進められる。
- Immichのdescriptionとvisibilityには更新APIがある。
  [v3.2.4 asset DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/asset.dto.ts)を基準にする。
  [enum](https://github.com/immich-app/immich/blob/v3.2.4/server/src/enum.ts#L1171-L1179)のhiddenはLive/Motionの付随動画用。
  Appleの非表示をhiddenやarchiveへ無断で置き換えない。lockedの読取り/変更は
  [昇格したsession権限](https://github.com/immich-app/immich/blob/v3.2.4/server/src/utils/access.ts#L116-L149)が必要で、
  現在のAPIキー接続にはない。[session unlock/lock API](https://github.com/immich-app/immich/blob/v3.2.4/server/src/controllers/auth.controller.ts#L159-L180)は存在し、
  [PINによる15分の昇格](https://github.com/immich-app/immich/blob/v3.2.4/server/src/services/auth.service.ts#L591-L609)には C-1（PR #24）で専用sessionを追加済み。実時間15分の経過受入れは未確認。
  permanentなAPI不能ではない。bulkでlockedへ変更すると
  [全アルバムから所属を解除](https://github.com/immich-app/immich/blob/v3.2.4/server/src/services/asset.service.ts#L176-L178)するため、
  確認と実際の所属結果を必要とする。再表示時に元所属へ自動復元できるとは保証しない。
- 監査したApple SDKの`PHAsset` / `PHAssetChangeRequest`にはcaptionの読書きがない。
  Photos側への同期を主張せず、アプリ独自の説明などの代替を区別する。
  Appleの人物/思い出の内部データ、専用調整/フィルターの同一画素再現も確認済み公開能力ではない。
  独自検索/分類/調整は実装可能だが、その代替をPhotos内部への同期と同じ到達条件にしない。
- 正確なPhotos内部との同期・同じアルゴリズムを必須とする場合は、API制約と代替を提示して
  到達条件を判断する。今は差分を記録し、可逆な実装や検証準備を止めない。
- 実機/iCloudのテスト対象と署名team/配布方式は、実際に必要となった時点で選択・アクセスを確認する。
  未入手の外部条件をlocal testsやSimulatorで通過扱いにしない。

## 既存記録の更新時に注意する点

photos-parity.mdには歴史的な検証記録も含まれる。最新の到達状態と取り違えないよう、
18画面と23画面のVRT、PR #19前後の実保存/復元証拠、
PHImageManagerからPHContentEditingInputへの現在画像取得の変更を整理する。
現在の画像のnative取得は奇数幅241画素を保持する修正を含むが、
実受信先での共有や実機/iCloudの確認まで完了した意味ではない。

すべての変更で`make check`、Apple境界変更で`make apple-build`、
Immich契約変更で`make integration`、SwiftUI変更で固定環境の`make vrt`を要求する。
必要なnative保存の証拠を別途取得し、レビュー後の最終HEADとマージ後mainのCIを分けて確認する。
golden更新は差分の確認と明示的な`make vrt-record`を経て行う。


## 保存先の方針の決定（2026-10-14）

Immich が編集レシピとして保存できない色・動画・Live Photo の編集は、利用者の選択により、編集済みの別コピーを Immich に保存する。既存の原本は上書き・削除しない。アプリ内だけにレシピを保存する案は、この保存方針として採用しない。PP-08 / PP-12 / PP-13 で別 asset の生成、メタデータ・関連ファイル・新規 ID、原本保持、送信前記録と中断後の結果確認を実装・検証する。これは方針の決定であり、現在の Apple 通常削除の作業によって実装済みにはならない。
