# Immich の通常アーカイブ操作

タイムラインとアーカイブの間で、所有する単独の静止画の表示先を変更する。
PIN付きロック操作とは別の認可型・確認画面・履歴を使う。
Live Photo、動画、stack、不明な関連情報を持つ写真はこの増分では対象外。

## 操作と保存

Rustが表示元のaccount/scope/ID、owner、原本の同一性、revision、現在の表示先を確認する。
通常認可の移動先はtimeline/archiveだけで、lockedを含まない。
確認取消し・認可失効時は送信しない。確定後、Unknownの意図を保存してからPUTを一度だけ行う。
応答消失時は再送せず、利用者の明示的な現在状態確認を提供する。
現在状態を確認しても、元の操作結果Unknownは書き換えない。

通常アーカイブではアルバム所属を解除しない。確認画面にもロック時の所属解除の説明を流用しない。
別の保存先にある同じ内容のコピーは変更対象にならない。
変更後は通常一覧の古い情報を無効化し、fresh scanで再取得する。

保存の応答が失われた場合は、実際の読戻しが保存前または保存予定の値と一致するかを調べる。
数値はnative JSONの整数/小数表記差だけを厳密に許容し、丸め誤差・項目欠落は許容しない。
どちらとも確認できない場合は通常書込みを停止する。
明示的な保存回復でも、その不確実な保存のbefore/desiredだけを採用する。
過去の同一scopeの操作、別accountの履歴、ロック操作、アプリ内保護、転送・削除等の記録を
欠いたデータを回復として採用しない。
照合用の二候補は不確実な間だけメモリに保持し、保存形式やSwift DTOへは追加しない。
再起動後は実際に保存されたjournalを読み、Unknownは現在状態確認から扱う。

## 認可と画面

SwiftはRustが発行したoperation ID、scope、key、scene、generation、移動先、URLと
実際のPUT本文を照合し、送信直前までnative gateの失効を同期する。
余分な本文項目や、PIN/通常コンテンツ用の認可を混在させた要求は拒否する。
背景移行、閉じる操作、account変更は古い確認と送信権限を失効させる。
送信済みの応答処理は最後まで処理し、画面を閉じたことを未送信の証拠にしない。

iOSは認可されたsceneのwindowに確認sheetを表示する。
macOSも登録された所有windowへ表示し、別のkey windowへ代替しない。
所有windowの非表示・最小化・破棄と、古いcallbackからの確定を拒否する。

## 保存形式と分離

schema 7ではvisibility操作にordinaryArchive/lockedTransitionの種別を持たせる。
旧schemaの記録はlockedTransitionとして移行し、種別と表示先の組合せも検証する。
通常履歴・現在状態確認からlockedTransitionを参照・更新しない。
PIN認可なしでlocked rosterへ項目を追加しない。
共有workflowの永続化と原本照合を再利用し、認可の種類は混同しない。

## 検証状況

この増分は未マージ。先行するC-2を統合後、同一treeのmain `23fa2f8` を基点に検証している。
C-2は最終HEADのCI全4 job成功後、PR #25としてmain `23fa2f8` へマージ済み。
マージ後mainは検証済みHEADと同じtreeで、main CIも全4 job成功。

- `make check`: Rust314件・Swift65件、lint・DTO生成確認が成功
  （`/tmp/suwop-archive-epoch-check2.log`）。
- `make apple-build`: Rust全5ターゲット、XCFramework、iOS/macOSが成功
  （`/tmp/suwop-archive-epoch-apple2.log`）。
- `make sharing-test`: 両確認アダプタと既存共有の計14件が成功
  （`/tmp/suwop-archive-final-sharing1.log`）。通常側の5件は非key所有window、
  閉鎖・置換、古いcallback、最小化、scene取消し、未登録・非表示・失効を検証する。
- 実Immich v3.2.4の結合4件が成功。PIN未設定での往復、2アルバムと原本保持、
  通常操作中の認証API呼出し0件を確認した（`/tmp/suwop-archive-integration8.log`）。
  focused Rust11件と全target/all-feature Clippyも成功した
  （`/tmp/suwop-archive-focused9.log`、`/tmp/suwop-archive-clippy-live4.log`）。
  専用Docker資源は検証後に削除済み。
- iOSの新規host11件・UI3件が成功
  （`/tmp/suwop-archive-functional-host2.log`、`/tmp/suwop-archive-ui1.log`）。
  UIはPIN不要の往復、両アルバムと原本保持、応答消失後のInspect限定と再送禁止、
  AX3での説明・取消し・確定を確認した。AX3の添付画像でも全文と両ボタンを確認した
  （`/tmp/suwop-archive-ui1-attachments`）。これらはC-2最終統合前の結果であり、
  統合後・取消処理修正後の全体VRTも成功した（下記）。
- 新規5画面を撮影し、通常文字とAX3の確認、空履歴、適用済み、不明の各画面を目視した
  （`/tmp/suwop-archive-screens-capture1`）。基準未登録の5件のみ失敗した。
  この5枚の基準追加を承認し、既存40枚はHEADと完全一致を維持して全体比較する。
  全体VRTは成功、hosted CIは未完了。

実API検証では、検索と詳細取得の間にupdatedAtが変わる競合を観測した
（`/tmp/suwop-archive-integration7.log`）。HTTP失敗・decode失敗・stack欠落・
時刻表記差ではなく、revision不一致のため製品が安全に操作不可としていた。
受入れfixtureは、そのRefresh内の厳密な競合証拠がある場合だけ、操作不可とPUT数不変を確認し、
有限の安定待機後に明示Refreshを1回行う。元の操作候補assertを保持し、
一般的なretryや変更の再送はしない。決定的なRust回帰でもこの復旧とPUT1回・確認1回を検証する。

保存回復の回帰では、別keyにある過去の同scope Unknown記録の欠落を拒否し、
正当なbefore/desiredだけを採用する。VRTはC-2と同じscene trait設定・復元と
描画安定待機を使用し、比較許容値を変更しない。

Simulator、macOSのNSAlert component、実Immich APIはそれぞれ別の証拠である。
実機・iCloud・手動の実アプリ複数window受入れは未検証。

追加レビューで、非activeからactiveへ戻る間に待機していた未送信commandが、
古いepochのまま確認画面を開ける経路を確認した。旧コードへ回帰テストを追加すると、
inactive/backgroundの両方で確認1回を検出して失敗した。保存とPUTは0回だった
（`/tmp/suwop-archive-command-epoch-red.log`）。非active遷移でsceneのcommand epochを
同期的に更新する1行の修正後、同じ回帰と既存の送信済み応答保持を含む12件が成功した
（`/tmp/suwop-archive-command-epoch-green.log`）。修正後のcheck Rust314／Swift65と
全Appleビルドも成功した（上記epoch-check2／epoch-apple2）。
以前のcheck／Appleログ名を再使用したため、修正前の当該2ログは残っていない。
最新結果は固有名へ移し、xcresult・report・画像は保持している。
最終strict VRTは終了0。45画面一致・差分0、host75件・UI36件が成功した
（`/tmp/suwop-archive-vrt-strict1.log`）。
`DerivedData/VRTArtifacts/20261015T082219Z-74460/report.json` はrecord=false・passed=true・
全7stage終了0。全45基準の実行前後hashが一致し、既存40枚はmainとバイト完全一致を維持した。

`make vrt-record` はhost74件・UI36件成功、全7stage終了0で完了した
（`/tmp/suwop-archive-vrt-record1.log`、`DerivedData/VRTArtifacts/20261015T080011Z-53636/report.json`）。
記録で書き換わった既存40枚はHEADとバイト完全一致へ復元し、新規5枚のみ追加した。
新規5枚は事前に目視した候補と全画素・alphaが完全一致した
（`/tmp/suwop-archive-record1-pixels.json`）。record=trueの実行であり、最終比較の成功ではない。
main基点への変更前にソース372ファイルを退避し、変更後も全hash一致を確認した
（`/tmp/suwop-archive-pre-mainbase-20261015-171827`）。

## PR #27 の通常確認とPIN一覧の分離

過去の通常アーカイブ履歴を持つ写真が後でロックされた場合、通常履歴のInspectが
PIN認証済み一覧と選択中画像を先に消していた。通常metadata取得はlocked写真の取得を拒否され、
通常認可からPIN一覧を再生成できないため、再認証まで項目が戻らなかった。
通常Inspectから一覧削除の呼出しを除き、読み取り側がPIN一覧へ干渉しないようにした。
確認済みのvisibility変更開始時とPIN認可付きInspectの処理は維持する。

回帰はRustのPIN認証・一覧取得・画像選択を実行してから、通常Inspectの403応答を処理する。
旧コードは一覧と画像の消失で失敗し、修正後は一覧・画像・grant全体が一致した。
追加認証0、保存0、PUT0、画像解放0も確認した
（`/tmp/suwop-archive-pr27-p2-red-20261015.log`、
`/tmp/suwop-archive-pr27-p2-green-20261015.log`）。
修正後の `make check` はRust315件・Swift65件とlint・生成確認が成功した
（`/tmp/suwop-archive-pr27-p2-check2-20261015.log`）。
App・Swift DTO・基準画像に変更はない。上記45画面／host75／UI36のローカルVRTは
修正前HEAD `f02f405` の結果であり、修正後HEADの全体VRT・PhotoKit・実Immich結合は
hosted CIで再確認する。
修正後のAppleビルドも全5 Rustターゲット・XCFramework・iOS/macOSが成功した
（`/tmp/suwop-archive-pr27-p2-apple-20261015.log`）。基準45枚はHEADと全hash一致。


## PR #27 の結果不明記録とPIN閲覧の分離

通常アーカイブの応答消失で残るUnknown記録が、後で外部からロックされた同じ写真の
PIN認証済み一覧と画像取得まで拒否していた。永続記録によるPIN閲覧拒否は
LockedTransitionに限定し、OrdinaryArchiveのUnknownでは認証済み閲覧を許可する。
アプリ内保護・一時的な拒否・PIN操作自体のUnknownによる保護は維持する。

Unknownの変更操作を許可する修正ではない。通常記録の結果不明が残る間は
書込みを引き続き拒否し、PIN一覧の変更候補も無効として表示する。
通常履歴をPIN履歴へ移したり、観測済みに書き換えたりはしない。

回帰テストはOrdinaryArchive／LockedTransitionと、メモリ上の状態／schema 7の保存・読込みの
4組でPIN認証、最新一覧、画像取得を実行する。旧コードでは通常Unknownの一覧が0件となり失敗した
（`/tmp/suwop-archive-pr27-p2-kind-red-20261015.log`）。修正後は通常Unknownのみ閲覧でき、
解除候補は無効、記録はUnknown・未観測のまま、変更要求によるHTTP・保存・PUTは0回だった
（`/tmp/suwop-archive-pr27-p2-kind-green-20261015.log`）。
最終 `make check` はRust316件・Swift65件とlint・生成確認が成功した
（`/tmp/suwop-archive-pr27-p2-kind-check2-20261015.log`）。
Appleビルドも全5 Rustターゲット・XCFramework・iOS/macOSが成功した
（`/tmp/suwop-archive-pr27-p2-kind-apple-20261015.log`）。基準45枚はHEADと全hash一致。
修正後HEADのhosted CIは別途確認する。


## PR #27 のsceneごとの確認取消し

共有sessionが別sceneのinactive/background通知を受けると、所有sceneで表示中の確認まで
全体invalidateしていた。sceneChangedからの取消しにsceneIDを渡す1行の修正で、
対象sceneだけを失効させる。接続変更・認可世代変更の全体失効は維持する。

回帰は別scene Bをactiveにした後、Aの実際のnative確認画面を表示する。
fixtureの確認差替えを外し、Bのinactive/background・closeではAの確認を保持し、
A自身のinactive/backgroundで取消し・保存0・PUT0になることを検査する。
修正前はBのinactive/backgroundの両方でAのdismissal開始を検出して失敗した
（`/tmp/suwop-archive-scoped-scene-red3-20261015.log` とxcresult）。
先行red/red2はSimulatorライブラリ／Xcode生成物の構成問題によるbuild失敗であり、
動作の再現証拠には使用しない。Simulatorライブラリとprojectを再生成し、別DerivedDataで再現した。

修正後は新規回帰、既存のcommand epoch失効、送信済み応答保持を含むhost13件が成功した
（`/tmp/suwop-archive-scoped-scene-green-20261015.log` とxcresult）。
`make check` と全Appleビルドも成功した
（`/tmp/suwop-archive-scoped-scene-check-20261015.log`、
`/tmp/suwop-archive-scoped-scene-apple-20261015.log`）。
最終strict VRTも成功した（`/tmp/suwop-archive-scoped-scene-vrt-20261015.log`、
`DerivedData/VRTArtifacts/20261015T094015Z-42516/report.json`）。host76件・UI36件が成功し、
45画像一致・差分0、全7段階の終了コード0、record=falseを確認した。
基準45枚は開始時・終了時・HEADのSHA256が一致し、更新していない。

先行HEAD `0c21a57` のhosted CIではcore・apple・Immich連携が成功した一方、
VRTのLive Photo未対応理由の表示領域検査1件が失敗し、PhotoKit段階は未実行だった。
その実行を成功扱いせず、保存されたxcresultと画面を別途調査する。
scene修正後HEADのhosted CIは別途確認する。


旧CIの録画（`/tmp/suwop-archive-ci-live-reason-20261015/at9s.png`）では、
Live Photo未対応の文言全体と無効な操作ボタンが表示されている。
即時に取得したAX firstMatchのframeが空だった一方、後続の同文言の画面内判定は成功した。
重複要素か一時的なAX状態かは断定せず、完全一致する文言のうち非空・画面内の要素を
最大5秒待つテストに変更した。無効ボタン・確認画面なし・表示領域の検査は維持し、
失敗時の画面とAX情報を保存する。製品コード・画像基準の変更は伴わない。
テスト修正後の対象UI全8件が成功した（`/tmp/suwop-archive-live-reason-ui2-20261015.log`
とxcresult）。説明表示の検査も成功した。先行ui実行は古いXcode生成物参照によるbuild失敗で、
動作検証には使用しない。別DerivedDataでビルド・実行した。最新HEADのhosted CIは別途確認する。

## 保存結果が不明な間の操作表示

最初の操作意図の保存と読戻しが両方失敗した場合、対象Aは一時的に表示から除外される。
一方、別の写真Bは一覧に残り、修正前はアーカイブ操作が有効に表示されていた。
Rustの実行入口は共通の保存不確定フラグで拒否するため、Bの操作が無反応になっていた。
同じフラグをRustの操作候補にも適用し、保存結果が不明な間は利用不可として表示する。
保存記録、対象Aの制限、再送禁止、復旧手順は変更しない。

2写真の回帰テストで、旧コードのBの候補がSome(Archive)になることを再現した
（`/tmp/suwop-archive-hint-p2-red-20261015-3.log`）。修正後の対象12件は成功した
（`/tmp/suwop-archive-hint-p2-green-20261015-2.log`）。Bへの新しい操作IDによる要求も
追加GET・保存・PUTを行わず、正しい保存状態の復旧後も再走査までは操作を再開しない。
再走査後に操作候補が戻ることと、復旧によるPUTが0であることを確認した。
先行red1/green1は対象Aの表示除外を考慮していないfixture、red2は修正済みコードの
確認手順に問題があり、旧動作の再現証拠には使用しない。

修正後のmake checkはRust/FFI317件・Swift65件が成功し、lintと生成確認も通過した
（`/tmp/suwop-archive-hint-p2-check-20261015-1.log`）。全5 Rustターゲット、
XCFramework、iOS/macOSビルドも成功した
（`/tmp/suwop-archive-hint-p2-apple-20261015-1.log`）。Swiftソースと基準画像は変更していない。
先行HEADのローカルstrict VRTと、新しいHEADのhosted CIは別の検証記録として扱う。
