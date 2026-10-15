# Immich のロック移動・再表示（PP-02C-2）

最新HEAD `ca1cfae` のCI run `38685755541` はcore・Apple・Immich integrationが成功し、VRTは失敗した。
失敗は既存 `apple-visibility-observed-large-text` の43,691画素差分と、stack理由表示の空frame assertion。
ローカルstrict VRTの成功とは区別し、CI成果物を使って描画・操作待機を修正した。基準画像と許容差は保持する。

CI録画ではstack理由全文と無効な操作が表示されており、空frameのAX要素を先に取得していた。
同じ全文を持つ要素のうち、画面内の空でないframeが確定するまで有限時間待つ。
画像比較では従来の最低待機を残し、基準を参照しない連続描画の全画素が3回安定した後、
採用した同じ画像を比較する。既存sRGB変換とRGB差2の条件を用い、4秒以内に安定しなければ失敗する。
修正前のローカル再検証では更新アイコンにも2,233画素の差分が再現した。
修正後は35画面の比較が2回成功し、stack操作UI2件も成功した
（`/tmp/suwop-roster-ci-focused3.log`、`/tmp/suwop-roster-ci-focused4.log`）。
このテスト修正後の全体strict VRTは終了0で成功した。全40画面、host62件、UI33件を通過し、
record=false、全7stage終了0、基準画像は変更していない
（`/tmp/suwop-roster-ci-vrt-final1.log`、`DerivedData/VRTArtifacts/20261015T055512Z-90218`）。
後述のmacOS修正を含む最終ソースの検証と新HEADのhosted CIは別途確認する。

追加レビューで、macOSの確認が認可sceneではなくkey/main windowを選ぶ問題が判明した。
別windowへのフォーカス移動で異なる文脈に確認が表示されるため、登録されたsceneの
所有windowへNSAlert sheetを表示する専用アダプタへ変更した。所有window不在・非表示・
最小化・失効時は中止し、表示後のowner登録差替えや古いcallbackからの確定も拒否する。
SwiftUI rootにmacOSの弱参照window anchorを登録する。Rustのgrant・scene・generationの
表示前後の検査は既存AppleShell経由で維持する。
修正後の `make check` はRust300件・Swift62件、`make sharing-test` は新規7件と既存2件が成功した
（`/tmp/suwop-c2-mac-check-final1.log`、`/tmp/suwop-c2-mac-sharing-final1.log`）。
macOSの実NSAlert componentとwindow状態の証拠であり、実アプリの手動複数window受入れではない。
修正後の `make apple-build` もRust全5ターゲット・XCFramework・iOS/macOSが終了0で成功した
（`/tmp/suwop-c2-mac-apple-final1.log`）。続く最終VRTでは更新アイコンの2,233画素差分が再発した
（`/tmp/suwop-c2-mac-vrt-final1.log`、`DerivedData/VRTArtifacts/20261015T061811Z-15278`）。
同実行はhost62件中画像1件失敗、UI33件はすべて成功し、比較stage65／全体終了2として完了した。
連続描画の安定だけでは2種類の安定したglyph状態を区別できず、解消済みとは扱わない。
scene/window/SwiftUIの文字サイズをcapture構築前から揃え、終了時にscene overrideを復元する
fixture修正を検証する。基準画像は保持する。hosted CI成功前にはマージしない。

共有していた旧worktreeの消失を検出したため、ソースを退避し、現在のworktreeごとに
独立したtools・target・DerivedDataへ切り替えた。消失の原因は未確認であり、
旧DerivedDataの成果物への参照は現存を保証しない。以下は独立環境での再検証結果である。
scene overrideは明示値がある場合だけ旧値を読み、capture終了後にその値または継承状態を復元する。
出力ディレクトリを作成したfocused検証は5画面・35画面とも成功し、全40画面の再実行も成功した
（`/tmp/suwop-c2-independent-scene-diagnostic2.log`、
`/tmp/suwop-c2-independent-scene-generic3.log`、
`/tmp/suwop-c2-independent-scene-repeat4.log`）。
基準40枚はHEADとbyte一致し、製品フォント・比較許容値は変更していない。
診断出力除去後の最終 `make check` は終了0でRust300件・Swift62件とlint・生成確認が成功した
（`/tmp/suwop-c2-independent-check-final1.log`）。
最終strict VRTも終了0で、40画面・host62件・UI33件すべて成功した。
record=false／passed=true、全7stage終了0、基準40枚はHEADとbyte一致する
（`/tmp/suwop-c2-independent-vrt-final2.log`、`DerivedData/VRTArtifacts/20261015T065530Z-30106`）。
末尾のsimctl診断収集警告はテスト結果と区別し、wrapper・shutdown・reportの終了0を確認した。
新HEADのhosted CIとmergeは未完了である。

PR #25でレビュー中。初期HEAD `7db5858` のローカル全gateと実Immich v3.2.4結合は成功した。レビューでstack状態が操作候補へ伝わらないP2指摘を修正し、修正後のローカル必須gateも成功した。以下の検証表は初期HEADの結果であり、修正後の必要な検証とhosted CIは別に確認する。C-1の専用PINセッションはPR #24でmerge済みで、最終HEADとmerge後のCI全4 jobが成功している。

最初の増分は、同じ利用者が所有する、関連動画とstackを持たない静止画のtimeline／archiveからlockedへの変更と、lockedから明示的に選択したtimeline／archiveへの変更を扱う。Live Photo、動画、関連状態が不明な写真は対応済みとしない。通常のtimelineとarchiveの相互変更は、PIN不要の別経路として残す。

## stack操作候補のレビュー修正

PR #25の初期HEADは、検索結果から`StoredAsset`へstack情報を引き継がず、後段では拒否するstack写真にも操作を提示していた。修正では未所属／所属あり／不明を保存し、所属あり・不明の操作を無効にする。旧保存データの欠落は不明として読む。

固定v3.2.4の検索応答はstackを省略するため、欠落を未所属とは扱わない。Rustが新しい列挙結果のexact IDに対して詳細メタデータだけを取得し、ID・owner・checksum・updatedAt・visibilityが一致した場合だけstack情報を補う。通常側は取得前後の世代、PIN側はsession状態と世代を検査する。取得失敗・競合は不明を維持し、原本やプレビュー取得の権限を拡張しない。修正後のRust全291件と追加focused 7件、Clippy、DTO生成が成功。実Immich結合2回目の3件も成功し、通常／PIN一覧の非stack写真の操作候補と、実2画像stackの両一覧での操作禁止を確認した（`/tmp/suwop-stack-integration2.log`）。初回401はテスト中のsession再利用を改め、準備用PIN sessionの取得・logoutを製品sessionから分離して解消した。製品の認証失効は変更していない。修正後の最終 `make check` も終了0で、Rust291件・Swift62件が成功した（`/tmp/suwop-stack-check-final1.log`）。修正後の `make apple-build` もRust全5ターゲット・XCFramework・iOS/macOSが終了0で成功した（`/tmp/suwop-stack-apple-final1.log`）。strict VRTも終了0で成功した。40画面・host54件・UI30件が通過し、record=false／passed=true、全7 stage終了0、基準画像は変更していない（`/tmp/suwop-stack-vrt-final1.log`、`DerivedData/VRTArtifacts/20261015T031020Z-14751`）。テスト後の診断収集にsimctl探索警告があり、診断収集の成功とは区別する。修正HEADのhosted CIは別途確認する。

## PIN一覧の更新に関する追加レビュー修正

HEAD `7850d9b` のCI run `38676055604` は全4 job成功。その追加レビューで、変更後も認証済み一覧に古い項目・操作候補が残る問題を確認した。修正中であり、このHEADのCI成功だけではマージしない。

確定後の対象を古い一覧から除き、変更後または明示的な状態確認で得た最新の写真情報を使って更新する。結果の永続化と、同じ接続先・認証・画面・操作世代、アプリ内保護を再検査した後に限り、ロック済みなら最新の項目を追加し、再表示済みなら除去を維持する。結果不明・失効・遅延応答からは追加しない。明示的な状態確認による現在の観測と、元の操作結果は分ける。

変更前の保存失敗で履歴が残らない場合にも同じセッションで回復できるよう、再認証不要の一覧更新を追加する。既存の認証期限を延長せず、結果不明の履歴を一覧更新だけで解決しない。修正後のRust全297件とClippy、DTO生成は成功した（`/tmp/suwop-visibility-projection-rust1.log`、`/tmp/suwop-visibility-projection-clippy2.log`、`/tmp/suwop-visibility-projection-generate1.log`）。実Immich結合3件も成功し、同一grantでlock直後のfresh項目追加と両unlock直後の除去を確認した。専用composeのcleanupも確認済み（`/tmp/suwop-visibility-projection-integration1.log`、終了0）。最終 `make check` も終了0で成功し、Swift62件を確認した（`/tmp/suwop-roster-check-final1.log`）。最終 `make apple-build` も終了0で、Rust全5ターゲット・XCFramework・iOS/macOSが成功した（`/tmp/suwop-roster-apple-final1.log`）。VRTと最終HEADのCIは別途確認する。

初回の一覧更新VRT captureでは、同一認証でのロック・再表示と、結果不明後の明示的確認からの画像再表示は実UIで成功した。一方、変更前の保存失敗からの一覧復旧は実UIでも失敗したため、受入れ未完了。host側にはテスト用認証タイマーを途中で解放する問題もあり、別に修正する。修正前Coreのfocused診断でも失敗を再現した。実際の失敗した保存要求から新規操作1件だけを除いた状態と、実際の読戻しデータはSwiftでの正規化後に全体一致する。一方、capturedAt／modifiedAtのDouble値1767225600.0はJSONで1767225600として出力される。Rust側の型付き日時と読戻し数値の比較を回帰テストで確認し、厳密な数値一致だけを許す修正を進める（`/tmp/suwop-roster-known-before-diagnostic1.log`、終了65）。ツールバー更新に伴う6画面の差分は目視済みだが、機能テストが通るまで基準画像は更新しない（`DerivedData/VRTArtifacts/20261015T035158Z-41325`）。

保存復旧の比較修正はC-2の2か所に限定した。JSONの項目・型・配列順を厳密に保持し、整数と浮動小数点の表現差だけはIEEE754から復元した正確な整数値で比較する。実際のStoredAsset日時で旧比較の不一致と新比較の一致を再現し、大きな整数、端数、欠落・未知項目の拒否も検証した。修正後はRust300件、Clippy、実Immich結合3件が成功した。結合用container・volume・networkの終了後削除も確認済み（`/tmp/suwop-readback-focused3.log`、`/tmp/suwop-readback-rust1.log`、`/tmp/suwop-readback-clippy2.log`、`/tmp/suwop-readback-integration1.log`、各終了0）。更新CoreのSimulatorライブラリでfocused host7件は成功し、既知の保存前失敗から同一認証で復旧できること、遅延応答の処理完了後も新認証の画像／期限切れの遮蔽を保持することを確認した（`/tmp/suwop-roster-focused-host2.log`、終了0）。実UI focused4件も成功した。保存前失敗からの同一認証での復旧、ロック後の画像再表示、両再表示先への移動後の除去、結果不明後の明示的な確認を実操作で確認している（`/tmp/suwop-roster-focused-ui2.log`）。診断出力除去後の最終 `make check` は終了0で、Swift ABI62件が成功した（`/tmp/suwop-readback-check-final1.log`）。最終 `make apple-build` も終了0で、全5ターゲット・XCFramework・iOS/macOSが成功した（`/tmp/suwop-readback-apple-final1.log`）。全体VRTと新HEADのCIはまだ未完了。

全体capture2は診断出力除去後のテストで、XCTAssertEqualの第2autoclosure内のthrowing encodeにtryがないためコンパイルで失敗した。両JSON変換を先に実行するテスト修正を行い、capture3で再検証する。製品コード・基準画像は変更していない（`/tmp/suwop-roster-vrt-capture2.log`）。

capture3は実UI33件が全成功した。host61件では意図した画面差分6件と、下記の旧prewrite期待3件のassertionが失敗し、全体の成功とは扱わない。新規roster／refresh host7件は成功。既存prewriteテストは「fresh scanは保存しない」という旧前提で不確実状態を期待していたが、現在のrefreshは保存を行い、fixture.startは書込み回数だけをリセットする。実before／readbackの一致を確認して既知の保存前失敗として検証し直す。読戻し不能時の全体書込み停止・Unknown保持はGuardTestsとRustの回帰で維持する。6画面のactualは目視済みcapture1と最大RGB差0／2／2／0／0／0、既存許容値2を超える画素は0であり、基準更新はまだ行わない。

旧prewrite期待を実際の保存状態に合わせ、実failed intentから新規操作だけを除いたbeforeと実readbackの全体一致をassertした。変更要求0・新規履歴なし・書込み0のまま、既知の未送信失敗では通常表示と転送能力を維持する。修正後の機能host59件（snapshot2件を除く）が全成功し、読戻し不能時の保護も全4 Guardテストで成功した（`/tmp/suwop-roster-functional-host3.log`、終了0）。同一製品ソースのcapture3 UI33全成功と画像レビューを根拠に、管理側が6画面だけの `make vrt-record` を明示承認した。対象外34枚を保持し、記録後に別実行のstrict VRTを必要とする。記録実行は終了0で、host61件・UI33件すべて成功した（`/tmp/suwop-roster-vrt-record1.log`、`DerivedData/VRTArtifacts/20261015T043813Z-54134`）。対象外34枚はbackupから戻し、全ハッシュ一致を確認した。承認6枚中5枚はcapture3と既存RGB許容値2以内、large-textだけ更新アイコンのサイズに2231画素の差があり、最終比較で描画の再現性を確認する。許容値・environmentは変更していない。

追加レビューで、旧一覧更新が通信待機中のまま閉じて再認証すると、SwiftのpendingRefreshが新しい認証へ残り更新ボタンを無効化する問題を確認した。旧Appで追加テストが0.456秒で再現し、UUID/grantごとの待機所有権へ変更した。修正後はrefresh4件・機能host60件が成功し、旧応答が新しい更新のbusyを解除しないことも確認した（`/tmp/suwop-roster-refresh-owner-red1.log`、`/tmp/suwop-roster-refresh-owner-green1.log`、`/tmp/suwop-roster-functional-host4.log`）。その後の記録なし40画面比較ではlarge-text更新アイコンだけ2231画素の差が再現したため、描画原因を調査している（`/tmp/suwop-roster-focused-visual2.log`、終了65）。待機所有権修正後の `make check` はRust300件・Swift62件、`make apple-build` は全5ターゲット・XCFramework・iOS/macOSが成功した（`/tmp/suwop-roster-owner-check-final1.log`、`/tmp/suwop-roster-owner-apple-final1.log`）。画面fixtureはSwiftUIのAX3とUIKitの文字サイズが不一致だった。windowのroot取付前にUIKit traitを同じサイズへ設定し、window／controller／navigation barへの継承をassertした。製品フォント・基準・許容値を変えず、記録なし40画面すべてが一致した（`/tmp/suwop-roster-focused-visual3.log`、終了0）。一時診断を除去し、対象navigation barの存在も検証した最終ソースでstrict VRTが成功した。40画面・host62件・UI33件、record=false／passed=true、全stage終了0。基準40枚は記録開始後の承認6枚だけ更新し、対象外34枚は元のbyte列を保持している（`/tmp/suwop-roster-vrt-final1.log`、`DerivedData/VRTArtifacts/20261015T045916Z-58575`）。末尾のsimctl診断収集警告はテスト成功と区別する。最終HEADのhosted CIはpush後に確認する。

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

## 初期HEADの検証状況

以下は初期HEAD `7db5858` の結果。stack修正後の検証は上記のレビュー修正節に記録する。個別に成功した検証を、変更後の全体成功に置き換えない。

| 対象 | 現在の証拠 | 最終判定 |
| --- | --- | --- |
| Rust／FFI・Swift ABI | Rust／FFI 288件（C-2回帰21件）、Swift 60件、Clippy・DTO生成が成功。追加結合fixtureのClippyも成功。 | 最終 `make check` 成功（`/tmp/suwop-visibility-check-final1.log`、終了0、Swift60件）。 |
| Apple build | 確認sheetとscene/window対応を含む最終ソースでRust全5ターゲット／XCFramework／iOS／macOSが成功。 | 最終 `make apple-build` 成功（`/tmp/suwop-visibility-apple-final1.log`、終了0）。 |
| 実Immich v3.2.4 | 結合5回目の全3件が成功。所有する2アルバムからの解除、timeline／archive再表示、所属の非自動復元、fresh scan後の通常表示、原本バイト一致、4回のPUT前の意図保存を確認。専用composeのcontainers／volumes／networkも削除確認済み。 | この範囲は成功。参照不能な全アルバム、Live／動画、実時間15分の期限は対象外。 |
| native確認sheet | 最終表示タイミング修正後のhost 5件が成功。未登録scene拒否、別key windowではなく所有windowへの表示、表示拒否後の再利用、古いcallback無効化、外部detach取消を確認。 | Simulatorの対象試験は成功。iPad複数windowの実機受入れではない。 |
| AX3操作・見た目 | 実gesture後に下段説明が固定ボタンより上へ収まることをassert。管理側が出力画像で必須説明・他コピー保持の説明・両ボタンを目視。取消時は意図保存・PUTとも0、続く確定時は変更1回。 | 対象操作・画像は成功。全UI通しは別に確認する。 |
| 全画面・UI | capture3で40画面を撮影。機能host 51件は成功。snapshot 2件のassertion失敗は新規基準未登録5枚と意図した既存4枚の差分。UI 28件すべて成功。capture自体は想定したsnapshot差分で終了2（内部compare 65）。 | strict VRT成功。40画面・host53件・UI28件が通過し、record=false／passed=true、全stage終了0。 |
| hosted CI・merge | C-2はPR #25、初期HEAD `7db5858` のCI run `38672739985` は全4 job成功。stack操作候補のP2修正を進めている。C-1 PR #24の最終HEAD・merge後CIは全4 job成功。 | C-2の証拠にC-1のCIを流用しない。 |
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
