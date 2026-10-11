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
| 写真編集、切り抜き・回転・明るさ・色・フィルター、元へ戻す | 未実装 | 非破壊編集と元の保持、編集キャンセル、native 読込と保存 |
| 動画トリム、Live Photo 編集 | 未実装 | 原本の保持と再生、対応形式・権限の確認 |
| 共有、原本 / 編集後の書き出し、取り込み、複製 | 原本ファイルのシステム共有を実装、単独 / 複数選択の native 画面とキャンセル・片付けを確認。編集後の共有・取り込み・複製は継続作業 | 動画の共有、受信先での保存、強制終了後の片付け |
| ゴミ箱、削除確認、復元、削除結果不明 | 移動後のゴミ箱のみ | native ゴミ箱との一致、結果不明の再実行を防ぐ、両側の保護 |
| 保存先確認・照合・Copy / Move | Rust / FFI / Immich テスト、PR #2 CI | 実 PhotoKit の RAW / Live / 編集済み / iCloud / バースト / 限定権限 |
| 場所、人物、分類、思い出、重複整理 | 未実装 | 検索・分類の実結果。公開 API で扱えない Photos 専用機能は差分と代替を明記 |
| 権限変更、通信断、再開、性能、アクセシビリティ | 一部の core / cancellation テスト | 拒否 / 限定 / フル、VoiceOver / 大文字、端末と大量写真、断線・再起動 |
| 署名・配布、iCloud 同期 | 未確認 | 実機のインストール、同じ Apple account の native 保存結果 |

各行は実装、local tests / build、CI、画面・操作、native 保存結果を別に記録する。未実装・未検証を残したまま目標全体を完了としない。次にアルバム・共有・編集・ゴミ箱と動画再生を広げる。

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
- `make check`: Rust 74 tests / Swift 19 tests、strict lint / format / architecture / generated DTO / hooks を通過。単一フィールドの変更、権限制限・不正入力・異なる所有者 / ID の事前拒否、保存結果が不明な場合の再実行防止、転送履歴の保持、調整後の Immich EXIF 日時を優先する Rust tests と、実 FFI で Date の小数秒・native 応答・状態保存を確認する Swift test を追加。
- PhotoKit の位置情報削除に対応する。Immich の null 座標更新は非対応のため、0 / 0 を削除の代わりに使わない。原本の EXIF 除去、地名検索・地図、任意のタイムゾーン選択、取り消し / 復元は未実装。
- `make apple-build`: Rust の Apple 5 target と iOS Simulator / macOS app builds を通過。最新版を既存の iPhone Simulator にインストール・起動した。Mac がロック中で操作ツールから画面へアクセスできないため、日時・座標の native 操作と保存後の再起動確認は未完了。
- local `make integration` は Docker daemon の socket が存在せず起動できない。実 Immich v3.2.4 に対する日時・timeZone・座標の更新と原本 checksum / 他の項目の保持を専用 CI で確認する。native 保存と最終 HEAD / main の hosted checks は別に記録する。
