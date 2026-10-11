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
| アルバム、作成・名前変更・削除、所属追加・解除 | 未実装 | 両 provider の既存アルバムと native 保存結果。アルバム削除で写真を削除しない |
| 写真編集、切り抜き・回転・明るさ・色・フィルター、元へ戻す | 未実装 | 非破壊編集と元の保持、編集キャンセル、native 読込と保存 |
| 動画トリム、Live Photo 編集 | 未実装 | 原本の保持と再生、対応形式・権限の確認 |
| 共有、原本 / 編集後の書き出し、取り込み、複製 | 転送コピーのみ | システム共有画面、複数写真・動画、ファイル保持と後片付け |
| ゴミ箱、削除確認、復元、削除結果不明 | 移動後のゴミ箱のみ | native ゴミ箱との一致、結果不明の再実行を防ぐ、両側の保護 |
| 保存先確認・照合・Copy / Move | Rust / FFI / Immich テスト、PR #2 CI | 実 PhotoKit の RAW / Live / 編集済み / iCloud / バースト / 限定権限 |
| 場所、人物、分類、思い出、重複整理 | 未実装 | 検索・分類の実結果。公開 API で扱えない Photos 専用機能は差分と代替を明記 |
| 権限変更、通信断、再開、性能、アクセシビリティ | 一部の core / cancellation テスト | 拒否 / 限定 / フル、VoiceOver / 大文字、端末と大量写真、断線・再起動 |
| 署名・配布、iCloud 同期 | 未確認 | 実機のインストール、同じ Apple account の native 保存結果 |

各行は実装、local tests / build、CI、画面・操作、native 保存結果を別に記録する。未実装・未検証を残したまま目標全体を完了としない。次にアルバム・共有・編集・ゴミ箱と動画再生を広げる。

## 閲覧・お気に入りの検証（2026-10-12）

- `make check`: Rust 41 tests、Swift 11 tests、厳格な lint / format / architecture / generated DTO / hook checks を通過。
- `make apple-build`: Rust の Apple 5 target と iOS Simulator / macOS のアプリビルドを通過。実機の署名・配布確認は含まない。
- Simulator の標準写真だけを使用。全画面の前後移動、ズームの accessibility action、月別表示、お気に入り追加と解除、再起動後の native 再読込、コレクション件数を確認。
- PhotoKit の変更用キューで MainActor を継承して crash する問題を再現・デバッガーで確認。`NativeChange` の Sendable callback bridge に修正し、off-main callback の回帰テストと native お気に入り保存を通過。取り込みとゴミ箱も同じ境界を使うが、今回その native 操作は未確認。
- Immich v3.2.4 のお気に入り true / false の保存確認を integration test に追加。local Docker は OrbStack の I/O エラーにより起動できず、local integration は未完了。Hosted CI の結果は PR で別途確認する。
- 同一写真の整理は Apple Photos / Immich 両方に反映する前提。部分成功は巻き戻さず一覧を更新して確認する。写真の変更で原本の照合証拠が無効になった場合は再照合が必要。
