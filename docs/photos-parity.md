# Photos と同じように使うための到達条件

目的は Apple Photos と Immich の写真に対して、日常の閲覧・整理・編集・共有をこのアプリ内で完結できること。Rust / Crux が操作の意味・検証・保存と Immich API を担当し、Swift は UI と native I/O を担当する。実装やビルドだけをもって完了とはしない。

参照: [Apple Photos の基本操作](https://support.apple.com/en-gb/guide/iphone/iphc259d0ac7/ios)、[アルバム操作](https://support.apple.com/en-gb/guide/iphone/iphc0fc668ab/26/ios/26)。

| 操作 | 現在の証拠 | 完了を証明する確認 |
| --- | --- | --- |
| ライブラリ、日付別閲覧、並べ替え、表示密度 | 実装済み。iPhone 17 Pro / iOS 26.4 で標準写真6枚のグリッド・月別表示を操作確認、Rust 並べ替えテスト | iPad / Mac の操作、日付不明・大量写真、表示密度と各並べ替えの native 操作 |
| 検索、保存先・メディア・お気に入りで絞る | Rust に実装・組み合わせと空結果・日付境界 / 夏時間のテスト。Simulator でお気に入りコレクション1件→解除後0件を確認 | 検索欄の native 操作、同一写真の操作後の再照合 |
| 複数選択、全選択、選択解除、一括操作 | native asset key を選択の基準として実装。操作確認は未完了 | 検索・並べ替え・ライブラリ更新をまたいだ選択、一括保存 |
| 全画面、前後移動、ズーム、動画、Live Photo | 静止画プレビュー・前後移動・ズーム、動画 / Live の原本再生を実装。Simulator で静止画、動画の再生・一時停止・巻き戻し、自作 Live Photo の復元・再生を確認 | 実機撮影 / Immich の Live、編集後の再生、音声、iPad / Mac、回転、取得停止、エラー・iCloud |
| お気に入り、非表示、日時・位置・説明の変更 | お気に入り、保存先ごとの日時・座標変更を実装。お気に入りは Simulator の PhotoKit 保存・再起動後の再読込・解除を確認。日時・座標の native 保存は検証中 | 日時・座標の native / Immich 保存、実機 / iCloud、取り消し、地図・地名検索。非表示・説明 |
| アルバム、作成・名前変更・削除、所属追加・解除 | 通常アルバムを実装。Rust / FFI テスト、Simulator の PhotoKit 作成・名前変更・写真追加 / 解除・再起動後の再取得を通過 | Immich の実 API CI、PhotoKit のアルバム削除、共有・スマートアルバム、並べ替え、実機 |
| 写真編集、切り抜き・回転・明るさ・色・フィルター、元へ戻す | Apple 静止画の切り抜き・90度回転・反転・編集履歴と保存、確認後の原本への復元を実装。Rust / 実FFI / Core Imageの画素・色空間テストを通過。PhotoKitの保存操作は未検証 | native 保存・再起動・既存編集の保持、Immich編集、HDR・透過、明るさ・色・フィルター、原本へ戻す |
| 動画トリム、Live Photo 編集 | 未実装 | 原本の保持と再生、対応形式・権限の確認 |
| 共有、原本 / 編集後の書き出し、取り込み、複製 | 原本ファイルのシステム共有を実装、単独 / 複数選択の native 画面とキャンセル・片付けを確認。選んだ表示元の現在の静止画共有を実装、Rust / 実FFI通過 | 現在の静止画のnative共有、動画／Live・複数選択の現在の内容、取り込み・複製、受信先での保存、強制終了後の片付け |
| ゴミ箱、削除確認、復元、削除結果不明 | Immich 3.2+ の単独・複数選択の通常削除、本人のゴミ箱一覧、復元、送信前の記録と読取による結果確認を実装。Rust / 実FFI / 14画面VRTを確認中 | [削除と復元](trash.md) の実API CI、実ライブラリの操作。Apple側の通常削除と公開復元APIの制約、両側の保護 |
| 保存先確認・照合・Copy / Move | Rust / FFI / Immich テスト、PR #2 CI | 実 PhotoKit の RAW / Live / 編集済み / iCloud / バースト / 限定権限 |
| 場所、人物、分類、思い出、重複整理 | 未実装 | 検索・分類の実結果。公開 API で扱えない Photos 専用機能は差分と代替を明記 |
| 権限変更、通信断、再開、性能、アクセシビリティ | 一部の core / cancellation テスト | 拒否 / 限定 / フル、VoiceOver / 大文字、端末と大量写真、断線・再起動 |
| 表示の退行検出 | simslim の専用 Simulator と実 Rust ABI の固定データで SwiftUI 14 画面を VRT 比較。明暗・大文字・選択・ビューア・情報・アルバム・設定・転送画面を確認し、一画素の故意の変更で失敗検出を確認 | [固定環境での VRT](vrt.md) を維持。iPad / Mac、編集・動画・Live の画面と操作、実写真・VoiceOver は別途確認 |
| 署名・配布、iCloud 同期 | 未確認 | 実機のインストール、同じ Apple account の native 保存結果 |

各行は実装、local tests / build、CI、画面・操作、native 保存結果を別に記録する。未実装・未検証を残したまま目標全体を完了としない。

## 現在の段階と残操作（2026-10-12 再監査）

main は `dc81e958225ac4da62b6dbb1216dec6aba56649b`。閲覧・検索・お気に入り・通常アルバム・原本共有・原本再生・日時／位置変更・Apple静止画の幾何編集・表示元選択・中断後のコピー再開・静止画の原本への復元・Appleの現在の画像共有がマージ済み。これらのコード・CIと、表に残る端末操作・PhotoKit保存・iCloudの未検証項目は別に扱う。

| 次の操作・差分 | 実装の場所・現在の状態 | 完了まで必要な証拠 |
| --- | --- | --- |
| 日時を保った新規コピーと中断後の再開 | PR #11 の最終HEAD `e280879` とマージ後main CIは全3 job通過。POST前の開始記録・固有ID照合・開始記録解除を含めてマージ済み | 確認画面と中断・再起動のnative操作 |
| Apple静止画の原本へ戻す | PR #12 の最終HEAD `dc8eb58` とマージ後main CIは全3 job通過。Rust 154／Swift 38 testsとApple build通過 | 実PhotoKitの保存→復元→再起動と競合確認 |
| 編集後の共有、取り込み、複製 | `codex/share-current-content` で選んだ表示元の現在の静止画を共有する操作を実装中。動画／Liveの現在の内容、複数選択、外部ファイル取り込み・複製は継続。転送用AppleImport effectを、これらの完了の証拠に数えない | 選んだ保存先と現在の見た目／原本の区別、元バイトの保持、受信／保存先の実結果、キャンセルと片付け |
| 通常の削除、非表示／再表示、復元 | Immich の独立した `RefreshTrash` / `ChangeTrash` / `ResolveTrash`、確認後の保持設定・対象再検証、送信前の記録、結果不明の書込停止を実装中。AppleTrashは現在Moveの完了からだけ要求する。非表示は未実装 | 実API CIとnative操作。Apple側の通常削除・復元案内の判断、非表示・再表示、一括選択と現在の権限・ID確認、両保存先の状態との一致 |
| 明るさ・色・フィルターと編集のコピー／貼り付け | 現行Rust編集モデルは整数の切り抜き・向きが中心。16MP上限、HDR・透過・24/48MP、Immichの書込みは残る | Rustに編集操作・履歴・保存検証を追加し、native画素／形式／メモリと保存・取り消し・元へ戻すを確認 |
| 動画／Live編集、説明、アルバムの並びとフォルダー、人物／場所／分類 | 未実装または表の継続項目。原本再生、日時／座標の編集、通常アルバムをこれらの代用にしない | 対応する各操作の現在API、原本・関連ファイル・所属の保持、実データ操作と再起動、アクセシビリティ・端末別確認 |

操作差分は検証環境と同じiOS 26の公式ガイドで再確認した。[編集と複数写真への編集のコピー](https://support.apple.com/guide/iphone/edit-photos-and-videos-iphb08064d57/26/ios/26)、[削除・非表示・復元](https://support.apple.com/guide/iphone/delete-or-hide-photos-and-videos-iphb4defbde9/26/ios/26)、[アルバムの並びとフォルダー](https://support.apple.com/guide/iphone/create-and-work-with-photo-albums-iphc0fc668ab/26/ios/26)を到達条件に含める。日常操作の残りと、実機／iCloud／音声／性能／VoiceOver／署名・配布の検証を、現在のテスト通過で完了に置き換えない。


## 閲覧・お気に入りの検証（2026-10-12）

- `make check`: Rust 42 tests、Swift 14 tests、厳格な lint / format / architecture / generated DTO / hook checks を通過。
- 実際の Immich レコード形式から Live Photo 本体と動画の組を catalog に渡す回帰テストを追加。統合後も通常動画に数えず、写真と Live Photo に分類する。
- `make apple-build`: Rust の Apple 5 target と iOS Simulator / macOS のアプリビルドを通過。実機の署名・配布確認は含まない。
- Simulator の標準写真だけを使用。全画面の前後移動、ズームの accessibility action、月別表示、お気に入り追加と解除、再起動後の native 再読込、コレクション件数を確認。
- PhotoKit の変更用キューで MainActor を継承して crash する問題を再現・デバッガーで確認。`NativeChange` の Sendable callback bridge に修正し、off-main callback の回帰テストと native お気に入り保存を通過。取り込みとゴミ箱も同じ境界を使うが、今回その native 操作は未確認。
- 削除用キュー内で要求した全 ID の完全一致と Rust の原本・メタデータ検証を再実行する。取得漏れ・異なる ID・重複・空の再取得は変更を開始せず、native completion が成功を返しても失敗を伝える回帰テストを通過。
- Immich v3.2.4 のお気に入り true / false の保存確認を integration test に追加。local Docker は OrbStack の I/O エラーにより起動できず、local integration は未完了。[PR #3 の最終 HEAD CI](https://github.com/rabe1028/suwop/actions/runs/38161334038) は core / apple / immich-integration の全 job が通過。マージ後 main の CI は別に確認する。
- 同一写真の整理は Apple Photos / Immich 両方に反映する前提。部分成功は巻き戻さず一覧を更新して確認する。写真の変更で原本の照合証拠が無効になった場合は再照合が必要。

## アルバムの実装と検証

- 保存先と scope を持つアルバム ID を使い、同じ名前でも統合しない。Apple Photos の通常アルバムと Immich の所有アルバムを扱う。Immich の他の所有者の共有アルバム、スマートアルバム、フォルダー、順番の編集は継続作業。
- Rust が最新のアルバム・権限を読み直して操作を検証し、保存後も所属・名前・削除結果を再取得する。結果が不明なら変更済みの可能性を表示し、アルバムの変更権限を無効にして再読込を案内する。
- PhotoKit の native adapter は変更キュー内でフルアクセス、collection の `canPerform`、全写真 ID の完全一致を確認する。アルバム削除と写真の削除には別の native API / Immich route を使う。
- `make check` は Rust 52 tests / Swift 15 tests を通過。Swift の新しいテストは実 FFI を通してアルバムの削除・再取得・保存を確認し、写真と転送履歴が残ることを確認する。
- Immich へ再接続できない場合も Apple のアルバム一覧を更新し、ローカルの作成・名前変更を実行できる回帰テストを通過。Immich の操作だけ再接続を要求する。
- `make apple-build` は Apple の Rust 5 target と iOS Simulator / macOS app builds を通過。iPhone 17 Pro / iOS 26.4 の標準写真6枚で、通常アルバム作成・名前変更・写真追加・再起動後の native 再取得・選択による所属解除（アルバム1枚→0枚、ライブラリ6枚を保持）を確認。アルバム削除の実 PhotoKit 操作、実機 / iCloud / iPad / Mac の操作は未確認。
- Immich v3.2.4 の実 API にアルバム作成・名前変更・所属追加・解除・削除後の写真保持を検証するケースを追加。[最初の album CI](https://github.com/rabe1028/suwop/actions/runs/38162729624) の integration job は通過。Linux gate は Rustup の Clippy インストール競合で停止。専用ディレクトリへの分離だけでは再発したため、新しい一時ディレクトリで明示的にインストールしてから検査する。バージョン検査も全出力を読み、producer を途中で終了させない shell 回帰テストを追加して local `make check` を通過。最終 HEAD CI は別に確認する。
- Apple の全画面プレビューは `.aspectFit` で全体を取得し、グリッドは `.aspectFill` で取得する。
- Simulator で横長写真を縦横比を保って表示し、アルバム内の閲覧が「1 / 1」になることを確認。拡大中の移動範囲を実際に収まった画像の寸法から求め、縮小時も補正する。パンの限界と回転・大文字の操作確認は継続する。
- ローカルの画面証拠は `target/acceptance/albums-20261012/` に保存。保存自体は VRT / golden 比較の通過を意味しない。
- [アルバムの最終 HEAD CI](https://github.com/rabe1028/suwop/actions/runs/38163855568)、[マージ後 main CI](https://github.com/rabe1028/suwop/actions/runs/38164333052) は別々に core / apple / immich-integration の全 job が通過。

## 原本ファイルの共有

- Rust が現在の catalog とアクセス権限から共有元を選ぶ。同一写真の両側を重複して共有せず、完全な原本の構成を保持できる Apple Photos を優先し、必要な場合だけ Immich へ再接続する。Live Photo 本体と単独の付随動画を重複して共有せず、RAW / JPEG が別の Immich asset でも両方の原本を選ぶ。既知の組の一方がオフライン・アクセス不可なら、片方だけの共有を拒否する。
- 共有前に原本を再取得し、共有用ファイルの SHA-1 / SHA-256 / バイト長を再確認。作業領域外のパスや不正なファイル名を拒否する。写真、接続、転送履歴は変更しない。
- `ShareFiles` effect は native 共有サービスが完了・キャンセルを返すまで待つ。途中で共有用ファイルを削除せず、終了後や取得失敗時に片付ける。片付けに失敗した場合もエラーを表示する。
- `make check`: Rust 58 tests / Swift 17 tests を通過。新しい実 FFI test はシステム共有の応答前に cleanup が発行されないことを確認する。Rust tests は成功・キャンセル、取得中断、作業領域外のパス、コピー後の内容変更、片付け失敗、Immich 原本の GET のみの取得も検証する。
- Simulator の初回原本取得で、PhotoKit の data callback が MainActor を継承して停止する問題を再現・crash log で確認。`FileDownloadGate` が Sendable callback を提供する構成に修正し、別 executor から呼び出す回帰テストと、直接の resource trailing callback を拒否する lint を追加した。
- `make apple-build`: Apple の Rust 5 target と iOS Simulator / macOS app builds を通過。
- iPhone 17 Pro / iOS 26.4 の標準写真で、単独 HEIC と HEIC + JPEG の複数選択から system share sheet の表示を確認。共有待ち中は元の名前・形式・全バイトを持つファイルが残り、原本との SHA-256 一致も別に確認。キャンセル後に今回の作業フォルダーが消え、写真6枚と選択を保持して操作が再開できることを確認した。写真を選択する読み上げアクションも native 操作で確認。
- 画面証拠は `target/acceptance/sharing-20261012/` に保存。受信先へは送信しておらず、受信先での保存、iPad の popover、macOS のサービス、実機 / iCloud / 動画 / Live / RAW と強制終了後の回収は別途確認する。初回 crash で残った空の一時ファイルもあり、強制終了後の回収は未完了。編集後の書き出し、位置情報の除去、Photos 固有の All Photos Data / iCloud Link とはまだ差がある。
- [共有の最終 HEAD CI](https://github.com/rabe1028/suwop/actions/runs/38166897018) は core / apple / immich-integration の全 job が通過。macOS picker の delegate は Swift 6.0 でも使える非isolated入口から MainActor へ渡し、local / hosted の両 compiler でビルドを確認した。マージ後 main は別に確認する。
- [共有のマージ後 main CI](https://github.com/rabe1028/suwop/actions/runs/38167458713) も全 job が通過。マージした main の tree は検証済み HEAD と一致する。

## 動画と Live Photo の原本再生

- Rust が1件の catalog photo から利用可能な原本を選び、同じメディア構成の Apple 側を優先する。単独の付随動画が ID 順で先に並んでも Live Photo 本体を選び、構成が不完全な場合に通常動画へ代替しない。プレビューの保存先も Rust が選び、完全な構成とアクセス可能な保存先を優先する。限定権限での読込を許可し、古い scope、オフライン、不完全な構成、複数写真の再生を拒否する。Apple から再生する場合は Immich の接続状態に依存しない。
- 原本を再取得・検証し、動画は1ファイル、Live Photo は静止画と対応する動画の2ファイルを選ぶ。コピー後も SHA-1 / SHA-256 / バイト長と作業領域内のパスを検証する。再生前の構成変化や必要な原本の欠落・重複を拒否する。
- Swift は AVKit の動画プレーヤーと PhotosUI の Live Photo view を表示する。原本の再生であることを画面に明記する。PhotoKit が2ファイルを Live Photo として復元できない場合はエラーを表示し、原本は変更しない。
- プレーヤーの停止・画面終了まで Rust effect を完了せず、終了後に作業ファイルを片付ける。取得失敗、内容の変化、native 再生のエラー・キャンセル、片付け失敗も回帰テストの対象。強制終了後の回収は共有と同じ継続課題。
- `make apple-build`: Apple の Rust 5 target、iOS Simulator / macOS app builds を通過。Rust / Swift の実 FFI で再生終了前に cleanup が発行されず、終了後にライブラリと履歴が残ることを確認。
- `make check`: Rust 67 tests / Swift 18 tests、strict lint / format / architecture / generated DTO / hooks を通過。追加のテストは利用可能な保存先の選択、限定権限、原本の欠落・重複、内容変化・パスの逸脱、native 終了待ち、キャンセル・片付け失敗、Immich の認証された GET のみの原本取得を確認する。
- iPhone 17 Pro / iOS 26.4 に自作の8秒動画を追加し、原本再生、5秒付近での一時停止、先頭への巻き戻しを確認。再生中のファイルは原本との SHA-256 一致を別に確認し、終了後に今回の作業フォルダーが消え、操作を再開できることを確認した。
- 自作の JPEG / MOV に同じ content identifier と still-image-time を書いたペアを、Simulator に Live Photo 1件として追加。PhotoKit で原本を取得し、PhotosUI の復元・再生・再生ボタンを確認。静止画 25,098 bytes / 動画 610,446 bytes は再生待ち中に原本との SHA-256 一致を別に確認し、終了後の今回の作業フォルダー削除・操作再開も確認した。実機で撮影した Live Photo の証拠には含めない。
- ローカルの画面証拠は `target/acceptance/playback-20261012/native-video.png` と `native-live.png`。自作 fixture の生成 source も同じディレクトリに保存。標準写真6枚・自作動画1件・Live Photo 1件を保持する。VRT / golden 比較、実機 / iCloud / Immich Live Photo / 音声 / 長い動画 / iPad / macOS の native 操作は未確認。編集後の再生と転送を待たないストリーミングも継続課題。
- 最初の Apple CI はテスト開始前の Clippy インストール競合で停止。Linux job と同じく、ジョブごとの空の Rustup 領域へ固定 toolchain / components を明示的にインストールしてから Apple checks を実行する。最終 HEAD の hosted checks は別に確認する。
- 古い PhotoKit SDK に `PHLivePhoto` の Sendable 適合がないため、callback から secure coding の `Data` を渡し、MainActor 上で復元する構成へ修正。Swift concurrency の検査を弱めずに local checks と Apple の5 target / 両 app builds を通過。修正版を同じ Simulator で再生・再生ボタン・終了まで操作し、両原本の内容一致、今回の作業フォルダー削除、操作再開を再確認。画面証拠は `target/acceptance/playback-20261012/native-live-secure-archive.png`。hosted の古い SDK は最終 HEAD CI で別に確認する。
- [再生の最終 HEAD CI](https://github.com/rabe1028/suwop/actions/runs/38171000690) と [マージ後 main CI](https://github.com/rabe1028/suwop/actions/runs/38171605408) は別々に core / apple / immich-integration の全 job が通過。最終 HEAD とマージ後 main の tree は一致する。hosted の Swift 6.0 / Xcode 16.4 でも secure coding の境界を含めて通過した。

## 保存先ごとの日時・位置情報

- 情報画面から保存先を選び、撮影日時または緯度・経度を変更する。関連する Live / RAW / JPEG が同じ保存先に複数ある場合は、1件の写真に属する完全な組を Rust が選び、半分だけの変更を拒否する。別の保存先には自動反映しない。
- フルアクセスと現在の scope を確認し、日時・タイムゾーンと座標を Rust で検証する。保存後の全 ID・値・Immich timeZone の再取得が一致した場合だけ成功扱い。応答が不明、欠落・重複・不一致、状態保存失敗の場合は再試行せず一覧の再読込を案内する。
- `make check`: Rust 77 tests / Swift 19 tests、strict lint / format / architecture / generated DTO / hooks を通過。単一フィールドの変更、権限制限・不正入力・異なる所有者 / ID の事前拒否、保存結果が不明な場合の再実行防止、転送履歴の保持、調整後の Immich EXIF 日時を優先する Rust tests と、実 FFI で Date の小数秒・native 応答・状態保存を確認する Swift test を追加。
- PhotoKit の位置情報削除に対応する。Immich の null 座標更新は非対応のため、0 / 0 を削除の代わりに使わない。原本の EXIF 除去、地名検索・地図、任意のタイムゾーン選択、取り消し / 復元は未実装。
- `make apple-build`: Rust の Apple 5 target と iOS Simulator / macOS app builds を通過。最新版を既存の iPhone Simulator にインストール・起動した。Mac がロック中で操作ツールから画面へアクセスできないため、日時・座標の native 操作と保存後の再起動確認は未完了。
- local `make integration` は Docker daemon の socket が存在せず起動できない。実 Immich v3.2.4 に対する日時・timeZone・座標の更新と原本 checksum / 他の項目の保持を専用 CI で確認する。native 保存と最終 HEAD / main の hosted checks は別に記録する。
- [初回の metadata CI](https://github.com/rabe1028/suwop/actions/runs/38174279455) は日時・timeZone の読戻しを通過した後、お気に入りを一律 false と期待したテストで失敗。fixture の2枚目は元からお気に入りだったため、編集前の ID・checksum・名前・お気に入り・ゴミ箱状態を取得し、日時と座標の変更後にそれぞれ保持されることを検証する形へ修正した。最終 HEAD で実通信テストを再実行する。

- [テスト前提修正後の CI](https://github.com/rabe1028/suwop/actions/runs/38174639762/attempts/2) は core / apple / immich-integration の全 job が通過。最初の attempt はコンテナ取得のレジストリ制限で停止し、統合 job のみを再実行した。その後のレビューで、Apple の日時・GPS変更が照合済み hash を消し、Immich と統合された写真が分かれる問題を修正。成功を確認できた同一の原本構成だけ hash と byte count を保持し、未照合の RAW 原本の hash は補わない。原本構成・種別・IDの変化、取得不完全、重複リソース、新しい hash の観測では旧 hash を流用しない。通常の再読込後も統合を保ち、旧 Move receipt の revision では削除を許可しない回帰テストを追加。
- レビュー修正後の [最終 HEAD CI](https://github.com/rabe1028/suwop/actions/runs/38177326243) は `e15e46a75668c69546c0991d92d7217650a3cb12` で core / apple / immich-integration の全 job が通過。[PR #7](https://github.com/rabe1028/suwop/pull/7) をマージし、main `aef156e6ecbef81285c72937dbe119dda7d249fa` と検証済み HEAD の tree が一致することを確認した。マージ後の [main CI](https://github.com/rabe1028/suwop/actions/runs/38177838317) と native 保存の確認は別に追跡する。

## お気に入り変更後の照合と結果不明

- 日時・位置情報と同じ原本構成の検証を、成功を確認できた PhotoKit のお気に入り変更にも適用した。最新の revision を保存しながら既知の原本 hash / byte count を保持するため、正常な再読込後も Apple Photos と Immich の統合を保つ。原本構成が変わった場合は旧 hash を流用しない。
- 全保存先の現在の scope、写真の所属とフルアクセスを最初の変更前に確認する。PhotoKit の変更キューでも権限、要求した全 ID と properties の変更可否を再確認する。
- 返却件数、重複のない全 ID とお気に入り値が一致しない場合、応答不明または保存記録失敗の場合は、その保存先への変更を一覧更新まで無効にする。確認済みの Apple の変更を、後の Immich の応答不明で巻き戻したり、両方を自動で再試行したりしない。
- `make check`: 厳格な quality / architecture / generated / hooks と Rust 84 tests / Swift 19 tests を通過。統合した写真の保持、古い Move revision の拒否、両側の古い scope / 権限制限で書込みゼロ、欠落・重複・異なる ID / 値、応答不明、永続化失敗、部分成功と再取得後の再操作を検証した。
- `make apple-build`: Rust の Apple 5 target と iOS Simulator / macOS app builds を通過。最新版を既存 Simulator にインストール・起動したが、Mac のロックが継続しているため、今回の変更後の native 操作は未完了。最終 HEAD CI / main CI と実機・iCloud・iPad・Mac の操作は別に確認する。
- [PR #8](https://github.com/rabe1028/suwop/pull/8) の最終 HEAD `bbc04e22fdc706676a81959ccc8c6ef9114e730b` の [CI](https://github.com/rabe1028/suwop/actions/runs/38178207124) は core / apple / immich-integration の全 job が通過。マージ後 main `455374c57ffdc85e672a96c623176ba0baf58d0a` と検証済み tree の一致も確認した。[main CI attempt 2](https://github.com/rabe1028/suwop/actions/runs/38178828044/attempts/2) も全 job が通過。最初の attempt はコンテナ取得のレジストリ制限でテスト前に停止し、全体の終了後に統合 job だけを再実行した。native 操作が未完了であることは変わらない。

## Apple 静止画の切り抜き・回転・反転

- Rust が保存先の1枚を選び、現在の scope・フルアクセス・完全な原本構成を確認する。Apple の1枚に属する RAW / JPEG の原本は同時に保持する。別の保存先や別の写真へ編集を書き込まない。Immich・動画・Live Photo の編集は選択画面に未対応と表示する。
- Rust が EXIF を反映した原本の整数座標で切り抜き、時計回りの90度回転、上下・左右の反転、取り消し・やり直しを管理する。「開始時に戻す」は既存の編集を保持した開始状態へ戻す。「原本へ戻す」は別の操作として未実装。
- PhotoKit の編集入力を取得し、認識できる原本ベースの Suwop 調整データだけを再構成する。既存の他アプリの編集や描画済みベースの調整は cannot-handle 経路で現在の見た目を入力とする。未知の調整を原本から再現できると偽って置き換えない。調整 ID・version・内容は Rust が定義する。
- Swift は Core Image の描画と PhotoKit の入出力を実行する。元の色空間を使い、PhotoKit が許可する JPEG / HEIC で出力する。HDR・透過・色空間不明・1,600万画素を超える入力は拒否する。画像のプロパティだけを取得した段階で Rust の同じ画素数制限を適用し、制限外の画像をデコードしない。小さく切り抜いても元画像の制限は解除しない。プレビューは1280px以内に縮小し、最新のプレビューを作れない状態で保存を有効にしない。24MP / 48MP・大型パノラマは、全体のRGBA bitmapを作らない描画方式と実機のメモリ検証を待つ。
- 保存直前の PhotoKit 変更キューで権限・対象・revision・content 編集可否を再確認する。保存後は実際の調整データ、描画後の寸法、再取得した全原本の SHA-256 / 長さ / 名前 / 役割と日時・お気に入り・GPS を確認する。Auxiliary の置換を許し、原本の欠落や変化は拒否する。結果不明や記録の保存失敗は一覧更新まで Apple の書込みを無効にし、自動再試行しない。新しい Move receipt は作らない。
- 編集画面は描画処理の停止を待ってから閉じる。ネイティブ入力の保持を解除してから作業領域を片付ける。解除に失敗した場合は使用中の可能性がある作業領域を保持し、エラーを表示する。旧SDKの非Sendableな入力と出力には、読取専用・構築後に不変・利用executorと寿命を限定した private capsule の例外を記載する。編集入力callbackにも明示的な Sendable を要求する strict lint を追加する。
- ローカル `make check`: Rust 104 tests / Swift 27 tests。幾何・既存編集・改ざん・古い scope / 権限 / revision・キャンセル・保存結果不一致・原本変化・永続化失敗・解放 / 片付け失敗、実FFIでの履歴と保存 / 解放順を確認。Core Imageの8通りの幾何とEXIFの8方向、切り抜きの画素位置、JPEG / HEIC の Display P3と向き・寸法、入力バイト保持を確認した。追加lintも正しいcallback2種の通過とactorを引き継ぐcallbackの拒否を実SwiftLintで確認。最終HEAD CIは別途記録する。
- `make apple-build`: Rust の Apple 5 target と iOS Simulator / macOS app builds を通過。Swift 6 strict concurrency / コンパイラ警告のエラー化を維持して、明示的なSendable callbackとネイティブ入力 / 出力の保持をコンパイルした。これをPhotoKit保存・操作の証拠には数えない。
- 最新版を既存Simulatorにインストール・起動し、保存された一覧のAppleフルアクセス・8枚・転送履歴0件を再読込した。ローカル `make integration` はDocker daemonのsocketが存在せず、テスト開始前に停止。実Immichはhosted CIで別に確認し、純粋な編集系列parserの契約テストを実Immich編集の証拠に数えない。
- Macのロックにより、Simulatorの編集画面操作・PhotoKit保存・再起動・既存のPhotos編集との往復は未検証。RAW、実機・iCloud・iPad・macOSのPhotoKit操作、HDR・透過、Immichの編集、明るさ・色・フィルター、原本へ戻す、編集後の共有は継続課題。コード / 画素テストをこれらの証拠に数えない。

- 初回 HEAD `dc692b18ef4bfbb58e0179ad3d0bed9b5d6dcc96` の [CI](https://github.com/rabe1028/suwop/actions/runs/38182484113) は core / apple / immich-integration の全 job が通過。その後のレビューで、200MPまで許す全解像度RGBA描画のメモリ不足を修正した。入力を16MPまでに制限し、デコード前のnative metadata取得とプレビュー / 保存にもRustの同じ判定を適用。16MP境界と、16,004,000画素の有効PNGがnative decode前に拒否される回帰テストを通過。修正後の最終HEAD CIとPhotoKit操作は別に確認する。

- 修正後の [最終 HEAD CI](https://github.com/rabe1028/suwop/actions/runs/38183831004) は `4cbb264a20d00601b7516e28f6d71c6b0511f37c` で全3 jobが通過。メモリに関するレビュー指摘を解消し、[PR #9](https://github.com/rabe1028/suwop/pull/9)をマージ。main `929fc0a74e02c4003ea0b00bdd0e6ad03f08e23a` と検証済み tree `698e8f4f14641f5eb8d7def0b75e24aa96094543` の一致を確認し、[main CI](https://github.com/rabe1028/suwop/actions/runs/38184421960)も別に全3 jobが通過。最終修正後のPhotoKit保存の画面操作は未検証。

## 統合した写真の表示元と編集後のプレビュー

- Rust が統合した原本の中から、表示する1枚の保存先を選び、Swift は選択肢と選択済みの表示を描画する。静止画のグリッドと全画面に同じ選択を使い、撮影日は表示中のコピーの値を使う。表示元の変更で写真や転送履歴を書き換えない。
- 選択は実際の asset key を保持するため、原本の照合で一覧が統合・分割されてもそのコピーを追う。削除されたコピーの選択は破棄する。選択した保存先がアクセス不可になった場合は別の見た目へ切り替えず、理由と明示的な再選択を提示する。選択の永続化は継続作業で、再起動時は既定の選択に戻る。
- 現在の Apple scope / Immich session と snapshot にある実レコードを照合し、異なる接続先、欠落、重複・曖昧な inventory を拒否する。プレビューは読取りなので、限定権限や原本が取得不完全・オフラインでも現在のアクセスを確認できる保存先のサムネイルは要求できる。表示元の検証は一覧全体に索引を1回作り、各タイルで全写真の再走査をしない。
- 選択したコピー、revision、原本・補助リソース、サーバーの version、アクセス状態を含めた Rust の cache identity を使う。表示元・内容・アクセス変更でグリッドと全画面の再読込を行い、ズーム位置も初期化する。検証して保存した編集のコピーを Rust が表示元に選ぶ。
- Immich v2.6以降の2系と3系では Rust が `edited=true` のプレビューを組み立てる。古い版と version 不明の従来の FFI 入力は原本側の取得を保持する。v2.0 / v2.6 / v3.0 / v3.2.4 の公式 DTO を確認し、v2.0には未定義のパラメーターを送らない。実通信での確認対象は v3.2.4。
- `make check`: Rust 113 tests / Swift 29 tests と strict lint / format / architecture / generated DTO / hooksを通過。コピーの切替と別写真の拒否、アクセス不可時の保持、カタログの再統合・分割・削除、scope / record / 重複の検証、cache identity、限定権限・オフラインの読取り、編集中の選択、保存後の表示元を確認。実 FFI でも選択と日時のDTO、cache identity、server versionに応じたURIを検証した。
- 実Immichテストに、4×3のPNGを切り抜き・回転し、編集系列を読み直し、編集後のJPEGプレビューの縦横比と変更前後のバイト列を確認し、原本の内容・checksum・名前・日時・お気に入りを保持するケースを追加。HTTP 200だけを編集反映の証拠にしない。編集済みの写真がMoveの削除対象にならないことも確認する。ローカル `make integration` はDocker socket不在でテスト前に停止し、この新しいケースの実通信は最終HEAD CIで別に検証する。
- `make apple-build` は Rust の Apple 5 target と iOS Simulator / macOS universal app builds を通過。保存先を選び直した後は、全画面の参照先もその asset key に変え、以前のコピーが一覧から消えても選択中のコピーを表示する。
- 保存先切替のnative画面、実サーバーの編集直後の待機表示、キャッシュの実操作・性能・VoiceOverは別の確認対象。Macのロックによりnative操作は未完了。Immich編集の書込みUIはまだ公開していない。
- 初回 HEAD `f97d8be50e1f2e3fc37c79342f776e679eeb855e` の [CI](https://github.com/rabe1028/suwop/actions/runs/38186039904) で core と実Immich v3.2.4の編集済みプレビュー検証が通過。レビューで、選択したコピーの削除後も別のコピーが残る場合の閲覧と、日付検索・並べ替え・日／月／年のグリッドが表示元の撮影日を使う処理を修正した。日付不明を別コピーの値で補わない。Swiftの表示カーソルはRustから受け取ったグループのキーだけを保持し、照合や表示元の選択は行わない。
- レビュー修正後の `make check` は Rust 114 tests / Swift 32 tests と全品質gateを通過。どちらのコピーを除いても生存するコピーを表示すること、グループの分割・統合、別写真・別accountへ戻らないこと、表示元による日付検索・新しい順／古い順・日付不明・アクセス不可の扱いを確認。修正後の `make apple-build` も全5 targetと両universal app buildsを通過。情報画面の見出しも同じ日時を使い、Swiftの統合写真の最大日時を選ぶ補助処理を除いた。最終HEAD CIは別に確認する。

## ライブラリで調整した撮影日時のコピー

- Apple Photos の creationDate を変更しても原本の EXIF は元の日時を持つ。Rust が新規作成された Immich コピーだけに、ライブラリ上の既知の絶対日時を `dateTimeOriginal` に設定する。UTC 表現で小数秒を保持し、ファイルの変更日時とは別に扱う。日時が不明なら EXIF 日時の変更を送らず、既存の重複写真のメタデータは変更しない。
- Apple ライブラリの元のタイムゾーンは取得できず、Immich側の時計表示の再現は保証しない。絶対時刻の照合許容差は1ms。原本の EXIF 日時・タイムゾーンのバイト列は保持する。sourceのタイムゾーンを明示的に追跡してコピーする機能は継続課題。
- 1年から9999年の有限な日時だけを受け付け、日時が不正ならアップロード前に拒否する。アップロード結果が未確定、メタデータ設定が失敗した場合も書込みを自動で再試行しない。別のコピーの独立したメタデータを守るため、既存の重複先と日時が異なれば従来通り Move の検証は失敗して元を残す。
- 1970年より前の小数秒を含む日時の検索は、秒を切り捨てて日付へ変換し、整数への変換で翌日にずらさない。表示元の日時と端末のタイムゾーンを使う方針は保持する。
- `make check` は Rust 120 tests / Swift 32 tests と全品質gateを通過。2系 / 3系の新規コピーのUTC日時・小数秒・ファイル日時・GPS / お気に入り、重複時の書込み抑止、日時不明、不正値の書込み前拒否、不明な応答の非再試行、1970年境界の日付検索を確認した。
- 実Immich用に、EXIF日時 `2020:01:02 03:04:05.125+09:00` を持つ4×3のPNGを2つ追加した。ExifToolで両fixtureを検証し、片方のArtist tagだけを変えて重複を避ける。原本EXIFが優先される対照例と、2024年のライブラリ日時を持つ新規コピーを比較し、プレビュー生成とメタデータ再抽出のキュー終了後に日時を読み直す。原本のバイト列と、重複した写真の日時・名前・checksum・お気に入りの保持も検証する。
- 原本のSHA-1 headerとSHA-256もfixtureの実バイト列から作り、サーバーのchecksumと一致を確認する。ローカル `make integration` はDocker socket不在でテスト前に停止。追加fixtureでの実通信と最終HEAD CIは別に確認する。
- `make apple-build` は全5 Rust targetのコンパイルを通過後、universal library生成がディスク不足で停止。今回のビルド用一時成果物とmacOSビルド成果物を通常のcleanで整理し、同じコードの再実行でRust全5 target、XCFramework、iOS Simulator / macOS universal app buildsを通過した。PhotoKitから実際に調整した写真をコピーする画面操作は未検証。
- 表示元の [PR #10](https://github.com/rabe1028/suwop/pull/10) は修正後の [最終HEAD CI](https://github.com/rabe1028/suwop/actions/runs/38187295514) が `41ecb1e4dd7adbe14a52553a0c47f65c46fd2f2d` で全3 jobを通過しマージ。main `97df205e6dd47464b9126d2cce060b7bbc2e8db9` と検証済み tree `2236e6774c78819337b36c878aa40e1e2619734f` の一致を確認した。[main CI](https://github.com/rabe1028/suwop/actions/runs/38188055368)も全3 jobを通過した。

- 日時が一致する通常の原本にも sidecar を生成する指摘を受け、`created` 後は EXIF 日時の抽出を読取りで待ち、一致する日時更新を省く。未完了時は Rust が250msの Wait を最大120回要求し、Swift がキャンセル可能な待機だけを実行する。読取りの停止・失敗・回数上限では追加のメタデータを書き込まない。調整が必要な日時と従来の位置情報設定で生じる sidecar の保護は維持する。
- 日時の一致、抽出待ち、キャンセル・読取り失敗・回数上限の回帰テストを追加し、Rust 123 tests / Swift 32 tests と全品質gateをローカルで通過。Apple向けもRust全5 target、XCFramework、iOS Simulator / macOS universal app buildsを通過した。3つ目の EXIF PNG はライブラリの撮影日時が元の EXIF と同じケースで、実サーバーに sidecar が作られず削除ブロッカーが付かないことを再抽出の前後で確認する。追加ケースの実通信・最終 HEAD CIは別に確認する。
- `091a7d0710271a92a8a6510f7c618c1c7d6f40e9` の [CI](https://github.com/rabe1028/suwop/actions/runs/38191693778) は全3 jobを通過し、3つ目の EXIF fixture の sidecar 不在と削除ブロッカー不在も実Immichで確認した。この HEAD は以下の再開修正を含まない。
- 追加レビューの抽出失敗後の復旧について、新規作成 ID をメタデータ読取り前に永続化する修正を追加。同じコピー操作の再実行では同一 source／原本／保存先だけを再検証し、PUT 未送信なら確認画面を経て続行する。原本ダウンロードの SHA-256・バイト長、名前・種類・SHA-1、コピー先の revision、アカウントと Live 関連 ID を検証する。POST・PUT の書込みは自動再試行しない。
- 送信前の `metadataStarted` 記録からは、原本と意図したメタデータが既に一致する場合だけ読取りで回復する。読取り失敗・キャンセル・回数上限と再起動、確認の停止・失敗、原本不一致、確認中の変更、結果不明の反映済み／未反映、記録保存失敗、ID重複、source変更と別accountを回帰テストで確認した。`make check` は Rust 132 tests / Swift 33 tests と全品質gateを通過。実 FFI でも作成済み ID の記録と再起動後の確認キャンセルで POST／PUT が発生しないことを確認した。再開修正後の Rust 全5 Apple target と XCFramework はコンパイルを通過。native 確認画面の macOS キャンセル処理を現行 NSWindow API に修正し、同じ Rust ライブラリで iOS Simulator／macOS universal app builds を再実行して通過した。最終 HEAD CI、実通信の停止／再開と native 確認画面は別に確認する。
- 再開修正の `b36ea31b4ca5a4eb93c7f744ef6aa647643a6c65` の [CI](https://github.com/rabe1028/suwop/actions/runs/38194709861) は全3 jobを通過。Apple全5 target・両app buildsと実Immichの3つの日時fixtureも通過した。このHEADは以下の記録解除操作を含まない。
- コピー先を手動で削除した場合や続行をやめる場合のため、転送画面に再開記録の明示的な解除を追加。native確認後、対象キーのローカル記録だけを解除し、写真・転送履歴・別scopeの記録を保持する。HTTP、認証、原本取得や写真の変更・削除を要求しない。キャンセル・確認応答不明・保存失敗では記録を保持する。再開記録の重複は同一キーだけを解除できる。400 / 404や読取りの失敗から写真が消えたと推測して自動解除しない。
- 記録解除を含む `make check` は Rust 137 tests / Swift 34 tests と全品質gateを通過。実FFIで確認と保存以外のeffectを要求せず、写真一覧・転送履歴を保持することも確認。初回の実行はディスク不足で停止し、作業用worktreeの通常のCargo／Swift clean後に再実行して通過した。native確認画面の操作・ネットワーク中断からの実際の復旧は未検証。
- 記録解除を含むRust全5 Apple targetとXCFrameworkをコンパイル。SwiftUIの行が誤った処理中プロパティを参照していたため修正し、行を小さなViewへ分割した。Rustを変更せず両app buildsを再実行し、iOS SimulatorとmacOS universal app buildsを通過。全体の `make apple-build` の通過は最終HEADのCIで別に確認する。
- 記録解除のHEAD `a5e76da7e1a556e127d85fc458b88da4676fa419` の [CI](https://github.com/rabe1028/suwop/actions/runs/38197260251) は全3 jobを通過し、aggregate Apple buildも確認できた。追加レビューの1ms境界の不一致を修正し、アップロードの要否・メタデータの読戻し・Move検証に有限かつinclusiveな同じ日時比較を使う。±1msの日時更新省略、±2msの調整、非有限なreadbackの拒否を追加し、`make check` はRust 139 tests／Swift 34 testsと全品質gateを通過。比較修正後の最終HEADのCIは別に確認する。
- 境界修正の `58511566610381b453c16468b75c634ec579ae4b` の [CI](https://github.com/rabe1028/suwop/actions/runs/38198244161) はcore／appleが通過し、統合jobはコンテナ取得のレジストリ制限でテスト前に停止。追加レビューに対応して、PUT前の記録保存失敗ではメモリ内の元のphaseへ戻す。未送信なのに結果不明として扱ったり、別の保存操作で誤ったphaseを永続化したりしない。一覧更新の保存を挟んだ後、同じセッション／再起動後の明示的な確認から1回だけPUTへ進める回帰テストを追加。`make check` はRust 140 tests／Swift 34 testsと全品質gateを通過。追加ケースの初回はディスク不足でテスト前に停止し、worktreeの通常のCargo／Swift clean後の全チェックで確認した。最終HEADの全CIは別に確認する。
- 保存失敗修正の `5c09723b90e47108571a56c13b316572230600b5` の [CI](https://github.com/rabe1028/suwop/actions/runs/38199226364) は全3 jobを通過。追加レビューでアップロード時のsafe_nameと原本照合の名前が不一致だったため、新規／再開の照合に実際に送信した安全な名前を使う。sourceの名前、種類とSHA-1、再開時の原本SHA-256・バイト長・revisionの検証は保持する。multipartの名前を実要求から返すfixtureで、スラッシュ・バックスラッシュ・引用符・CR/LF・空文字と末尾スラッシュの6ケースの新規／再開を確認し、`make check` はRust 141 tests／Swift 34 testsと全品質gateを通過。名前修正後の最終HEAD CIは別に確認する。

- POST 前に開始記録と固有 ID を保存し、Immich の新規作成時の custom metadata にだけ識別子を添付する。作成 ID の保存失敗や応答消失後はチェックサムと識別子を読み取りで照合してから、作成済み原本の再検証と確認画面へ進む。識別子のない既存重複、ゴミ箱内、欠落・曖昧な応答では書込みを止め、不明な POST の再送はしない。転送画面から開始記録だけを明示的に解除できる。2.0 / 3.2.4 の公式作成・照合・metadata APIを確認し、実通信の検証対象は3.2.4。

- POST 前の開始記録・読み取り照合・失敗時の状態復元を追加した `make check` は Rust 148 tests／Swift 36 tests と全品質 gate が通過。生成時の一時容量を抑えるため、ローカル検証は Rust のサイズ最適化・単一 codegen unit・debug 情報なしで行った。全ターゲットの Apple ビルドと、最終 HEAD の実 Immich CI は別に確認する。

- 開始記録追加後の Apple Rust 5ターゲットをコンパイルし、XCFrameworkを生成。ローカルの一括 `make apple-build` は5番目のターゲットで容量不足により停止したため、残りのターゲットと組み立て工程を同じソースで実行した。Swiftの開始記録解除の不要な try/catch を除き、strict SwiftLint と iOS Simulator / universal macOS の両アプリの再ビルドが通過。PhotoKitの実操作の証拠には数えない。
- 容量が厳しい環境向けに `SUWOP_CLEAN_CHECK=1` で各Rust工程間のキャッシュをcleanするオプションを追加した。通常の全チェックと生成済みSwift用ライブラリを保持する。最終作業ツリーの再検証は継続中で、繰り返す No space left on device により未完了。最終コミット・push・CI・マージは未実施。

- 空き容量回復後の最終ソースで通常の `make check` が Rust 148 tests／Swift 36 tests と全品質gateを通過。`make apple-build` も一括コマンドでRust 5ターゲット・XCFramework・iOS Simulator／universal macOS両アプリを通過した。アーカイブは削除していない。ローカル `make integration` は再確認でもDocker socket不在で開始できず、最終HEADのhosted実Immich CIを必要とする。Macは現在もロックされ、native確認・PhotoKit保存の画面操作は未検証。

- `SUWOP_CLEAN_CHECK=1 make check` の実行経路も、Clippy／生成物確認／全Rustテスト／Swift用ライブラリ生成を順に完了し、各工程の完了後にRustキャッシュをcleanして通過。Rust 148 tests／Swift 36 testsは通常経路と同じで、生成済みSwiftライブラリを残した実ABIテストまで確認した。通常経路ではキャッシュを保持する。

## 保存先を指定した原本への復元

- Apple Photos の静止画を1件選び、native の編集能力と調整データを確認してから保存先・名前とすべての画像編集の破棄を提示する。キャンセル・確認失敗では原本のダウンロードや書込みを行わない。他アプリの編集も破棄すること、iCloud の同期を明示する。
- 確認後の原本 export と native 変更キューで同じ revision・元の構成・メタデータを再検証する。PhotoKit の復元 API を1回だけ呼び、調整データのない readback と原本の再 export を検証する。画素の再符号化を行わず、16MP の描画上限とは別の経路を使う。高画素・HDR・透過・RAW の実 PhotoKit 動作は未検証。
- RAW／JPEG を含む元のリソースの組・SHA-256・バイト長・名前、撮影日時・座標・お気に入りを保持する。別の保存先のコピーと転送履歴は変更しない。検証後のコピーを表示元にする。動画・Live PhotoとImmichの復元は未対応。
- 確認前／後の競合、フルアクセスなし、重複 ID／snapshot、欠落した原本、原本・位置の不一致、復元後に残る編集、失われた応答、永続化失敗、cleanup失敗を回帰テストで検証する。結果不明時は一覧更新まで Apple の書込みを止め、自動再試行しない。
- 日付コピー・安全な再開・再開記録解除と組み合わせた `make check` は Rust 143 tests / Swift 36 tests と全品質gateを通過。実 FFI でも確認・書込み・原本再読込・永続化・cleanup 順を検証した。Apple builds、最終 HEAD CI、実 PhotoKit での保存・復元・再起動・他アプリの編集との往復、端末／iCloudは別の確認対象。Macのロックによりnative操作は未完了。
- 同じコードの `make apple-build` はRust全5 target・XCFramework・iOS Simulator／macOS universal app buildsを通過。これはnativeで編集を保存して戻す操作の証拠には数えない。追加の日時許容差修正を含む最終HEADは別途検証する。
- 1ms境界の共通比較を含む最終ローカル `make check` はRust 145 tests／Swift 36 testsと全品質gateを通過。初回はディスク不足で停止し、作業用worktreeのCargo／Swift clean後の再実行で通過した。DTOとnative adapterは直前のAppleビルドから変更していない。最終HEAD CIのAppleコンパイルと実操作は別に確認する。
- PUT前の保存失敗修正も含むローカル `make check` はRust 146 tests／Swift 36 testsと全品質gateを通過。復元の変更を含むDTO・native adapterのAppleビルドは上記で確認済み。最新HEADでの全targetコンパイルと実PhotoKit操作は別途確認する。
- ファイル名照合修正も含むローカル `make check` はRust 147 tests／Swift 36 testsと全品質gateを通過。新規コピーと再開時の送信名の検証を継承し、復元前後の原本の名前・役割・バイト列の厳密な照合は維持する。最終HEAD CIとnative操作は別に確認する。

- [PR #11](https://github.com/rabe1028/suwop/pull/11) final HEAD `e280879a4b5f190852ad87ad3de41b7981efaf34` passed all three jobs in [CI](https://github.com/rabe1028/suwop/actions/runs/38222027294). All eight review threads were resolved before merge. Main `9c55d445cf3516aa64ef48d1a2c8da13f68049cf` matches verified tree `1becc063978425bc25393589fdf1ef7c08f27825`; its separate [main CI](https://github.com/rabe1028/suwop/actions/runs/38258154143) also passed core, actual Immich and Apple jobs.
- Reversion was rebased onto this main with both upload-intent and reversion confirmation DTOs preserved and regenerated from Rust. The combined `make check` passed 154 Rust / 38 Swift tests and all gates. Reversion's final Apple build, pushed-HEAD CI and actual PhotoKit interaction are separate evidence.

- On merged PR #11/main, reversion's aggregate `make apple-build` passed all five Rust Apple targets, XCFramework generation and both iOS Simulator / universal macOS app builds. This validates the composed native confirmation DTOs and thin PhotoKit adapter; it does not establish actual PhotoKit save/revert, restart, foreign-editor, device or iCloud acceptance.

- [PR #12](https://github.com/rabe1028/suwop/pull/12) final HEAD `dc8eb5861dceec915a34963826d6015bf90df672` passed core, actual Immich and Apple jobs in [CI](https://github.com/rabe1028/suwop/actions/runs/38260560253). Merged main `1c9d3480c57da52739959efd3f1877530af926ed` matches verified tree `79a5e094b32d08a910e393c5c43194f5382ca6a7`; its separate [main CI](https://github.com/rabe1028/suwop/actions/runs/38261955498) also passed all three jobs.

## 選んだ表示元の現在の静止画を共有

- 全画面の共有メニューから、表示元の現在の静止画と原本ファイルを選び分ける。Rustが現在のscope・一意なsnapshot／ID・明示された保存先を検証し、別の保存先へ自動で切り替えない。限定権限はアクセスできる静止画の読取りに使える。動画・Live Photoと複数選択の現在の内容は継続作業。
- Appleのadapterは [現在の全サイズ画像を返すPhotoKit API](https://developer.apple.com/documentation/photos/phimagemanager/requestimagedataandorientation(for:options:resulthandler:)) を使い、取得前後の写真情報をRustへ返す。キャンセル・低品質結果・エラーでは共有しない。ImageIOでコンテナ情報だけを読み、APIの向きと実際のファイルの向きを照合する。画素展開・再圧縮は行わず、編集rendererの16MP上限を適用しない。
- Immichは未編集と確認できた写真だけを取得し、保存されたSHA-1とバイト長も照合する。編集済み・編集状態不明では共有を停止する。編集を保存してから生成jobをqueueする[Immich v3.2.4の実装](https://github.com/immich-app/immich/blob/v3.2.4/server/src/services/asset.service.ts#L582)では、古い編集済みfullsizeファイルが残り得る。ファイルID・編集フラグ・更新日時だけを、最新の編集との対応の証拠には数えない。最新の編集系列を読み直して原本から書き出す方式を残タスクとして扱い、原本や古い生成画像へすり替えない。
- Rustが画像形式・サイズ・向き・単一frame・作業領域内のパス・安全な名前を検証し、共有用コピーのSHA-256・SHA-1・バイト長を照合する。システム共有の完了／キャンセルまでファイルを保持し、cleanup失敗も表示する。写真・転送履歴を書き換えるeffectを要求しない。Swiftに新しいImmich routeを置く変更も実装境界gateで拒否する。
- `make check` はRust 160 tests／Swift 40 testsと全品質gateを通過。実FFIで取得・ハッシュ・コピー・共有・キャンセル・片付けの順と原本／履歴の保持を検証。16MPを超えるPNGを画素展開せず検査し、ファイルのバイト列を保持し、向きの不一致を拒否するnative metadata testも通過。
- PR #13では、世代を確認できない編集済み共有を拒否する構成でRust 160／Swift 40 testsと全品質gate・全Apple buildを通過。[最終HEAD `2444e56` のCI](https://github.com/rabe1028/suwop/actions/runs/38271968656)は全3 job通過し、レビュー2件を解消してマージした。main `92b987f2c20cfbe19b82fc99a3a29f2ba297ee17`は検証済みtree `6a3991cc549728a46ff39d83e331049ecd10e9b8`と一致し、[別のmain CI](https://github.com/rabe1028/suwop/actions/runs/38273302918)も全3 job通過。local integrationはDocker socket不在でテスト前に停止。native共有画面と受信先の保存・実機／iCloud／HDR／RAWは別途確認する。

## Immichの最新の編集系列からPNGを書き出す

- `codex/render-current-immich`で、最新の編集系列を取得し、検証した原本に適用する読取り専用の書き出しを実装。古い生成済みfullsize／previewは使用しない。書き出し後に同じ編集ID・順序・パラメーターと写真の状態を読み直し、変更があれば共有を停止する。Immichの原本と編集系列は変更しない。
- RustがSHA-1とバイト長、EXIFで向きを補正した整数の切り抜き・90度回転・反転、日時と座標、出力のサイズ・向き・メタデータを検証する。Swiftは原本のNative情報を読み、Rustの描画計画に従ってPNGを生成する。キャンセルではNative workerの終了を待ち、処理中のファイルをcleanupで消さない。
- JPEGの再圧縮による追加劣化を避けるPNG出力で、Display P3・8bit透過、撮影日時と小数秒・UTCオフセット・GPSを保持する。未知の系列、HDR、色空間不明、1,600万画素を超える描画、メタデータ不一致を拒否する。Appleの現在の画像と未編集原本のバイト列をそのまま共有する経路には描画上限を追加しない。
- `make check`はRust 165／Swift 42 testsと全品質gateを通過。実Nativeの画素・Display P3・透過の反転・日時と位置の読み戻し・元バイト保持を確認。Rustは最新系列の変更、非対応操作、誤った出力・メタデータ、HDR・上限・不正日時・部分座標を拒否する。実Immichのfixtureも最新系列と原本の取得・再検証を使う経路へ更新した。
- `make apple-build`はRust全5 target・XCFramework・iOS Simulator／macOS universal app buildsを通過。最終HEAD CIの実通信、実際の共有画面と受信先の保存・実機／iCloud／高解像度／HDRは別に確認する。
