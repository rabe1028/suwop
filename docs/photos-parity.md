# Photos と同じように使うための到達条件

目的は Apple Photos と Immich の写真に対して、日常の閲覧・整理・編集・共有をこのアプリ内で完結できること。Rust / Crux が操作の意味・検証・保存と Immich API を担当し、Swift は UI と native I/O を担当する。実装やビルドだけをもって完了とはしない。

参照: [Apple Photos の基本操作](https://support.apple.com/en-gb/guide/iphone/iphc259d0ac7/ios)、[アルバム操作](https://support.apple.com/en-gb/guide/iphone/iphc0fc668ab/26/ios/26)。

| 操作 | 現在の証拠 | 完了を証明する確認 |
| --- | --- | --- |
| ライブラリ、日付別閲覧、並べ替え、表示密度 | 実装済み。iPhone 17 Pro / iOS 26.4 で標準写真6枚のグリッド・月別表示を操作確認、Rust 並べ替えテスト | iPad / Mac の操作、日付不明・大量写真、表示密度と各並べ替えの native 操作 |
| 検索、保存先・メディア・お気に入りで絞る | Rust に実装・組み合わせと空結果・日付境界 / 夏時間のテスト。Simulator でお気に入りコレクション1件→解除後0件を確認 | 検索欄の native 操作、同一写真の操作後の再照合 |
| 複数選択、全選択、選択解除、一括操作 | native asset key を選択の基準として実装。操作確認は未完了 | 検索・並べ替え・ライブラリ更新をまたいだ選択、一括保存 |
| 全画面、前後移動、ズーム、動画、Live Photo | 静止画の高解像度プレビュー・前後移動・ズームを実装、Simulator で確認。動画 / Live 再生は未実装 | iPad / Mac、回転・再生、取得停止、エラー・iCloud |
| お気に入り、非表示、日時・位置・説明の変更 | お気に入りを実装。Simulator の PhotoKit 保存・再起動後の再読込・解除を確認。他の変更は未実装 | Immich 保存の CI、実機 / iCloud、途中失敗時の表示。非表示・日時・位置・説明 |
| アルバム、作成・名前変更・削除、所属追加・解除 | 通常アルバムを実装。Rust / FFI テスト、Simulator の PhotoKit 作成・名前変更・写真追加 / 解除・再起動後の再取得を通過 | Immich の実 API CI、PhotoKit のアルバム削除、共有・スマートアルバム、並べ替え、実機 |
| 写真編集、切り抜き・回転・明るさ・色・フィルター、元へ戻す | 未実装 | 非破壊編集と元の保持、編集キャンセル、native 読込と保存 |
| 動画トリム、Live Photo 編集 | 未実装 | 原本の保持と再生、対応形式・権限の確認 |
| 共有、原本 / 編集後の書き出し、取り込み、複製 | 原本ファイルのシステム共有を実装、Rust / FFI で保持と後片付けを確認。編集後の共有・取り込み・複製は継続作業 | システム共有画面の native 操作、複数写真・動画、受信先での保存、強制終了後の片付け |
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

- Rust が現在の catalog とアクセス権限から共有元を選ぶ。同一写真の両側を重複して共有せず、利用可能な Apple Photos を優先し、必要な場合だけ Immich へ再接続する。
- 共有前に原本を再取得し、共有用ファイルの SHA-1 / SHA-256 / バイト長を再確認。作業領域外のパスや不正なファイル名を拒否する。写真、接続、転送履歴は変更しない。
- `ShareFiles` effect は native 共有サービスが完了・キャンセルを返すまで待つ。途中で共有用ファイルを削除せず、終了後や取得失敗時に片付ける。片付けに失敗した場合もエラーを表示する。
- `make check`: Rust 58 tests / Swift 17 tests を通過。新しい実 FFI test はシステム共有の応答前に cleanup が発行されないことを確認する。Rust tests は成功・キャンセル、取得中断、作業領域外のパス、コピー後の内容変更、片付け失敗、Immich 原本の GET のみの取得も検証する。
- Simulator の初回原本取得で、PhotoKit の data callback が MainActor を継承して停止する問題を再現・crash log で確認。`FileDownloadGate` が Sendable callback を提供する構成に修正し、別 executor から呼び出す回帰テストと、直接の resource trailing callback を拒否する lint を追加した。
- `make apple-build`: Apple の Rust 5 target と iOS Simulator / macOS app builds を通過。
- iPhone 17 Pro / iOS 26.4 の標準写真で、単独 HEIC と HEIC + JPEG の複数選択から system share sheet の表示を確認。共有待ち中は元の名前・形式・全バイトを持つファイルが残り、原本との SHA-256 一致も別に確認。キャンセル後に今回の作業フォルダーが消え、写真6枚と選択を保持して操作が再開できることを確認した。写真を選択する読み上げアクションも native 操作で確認。
- 画面証拠は `target/acceptance/sharing-20261012/` に保存。受信先へは送信しておらず、受信先での保存、iPad の popover、macOS のサービス、実機 / iCloud / 動画 / Live / RAW と強制終了後の回収は別途確認する。初回 crash で残った空の一時ファイルもあり、強制終了後の回収は未完了。編集後の書き出し、位置情報の除去、Photos 固有の All Photos Data / iCloud Link とはまだ差がある。
