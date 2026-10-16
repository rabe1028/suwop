# 選択したImmich動画の表示先変更

Immich 3.3.3で、選択した物理VIDEOのlocked／timeline／archive変更を扱う。3.2.4は読取り・確認を維持し、この変更のintent保存やPUTを開始しない。Live Photoの複数資源をまとめて変更する操作は別の未完了項目である。

## 書込みと終了待ち

Rustが選択資産の読取り・取得期限更新を失効させ、nativeの再生、読取り、準備、後処理の終了確認を待つ。quote生成前の処理や、すでに失効した所有者も対象にする。終了確認後に現在権限を再確認し、Unknown intentを永続化してから、最新の物理ID・原本署名・版・表示先・対応APIを照合して変更する。

終了確認失敗、保存失敗、古い権限、確認キャンセルは書込み許可にならない。古い終了処理は置換後の新しい所有者のファイルを削除しない。応答消失はUnknownのまま保持し、再起動後も自動再送しない。現在の表示先の読取り結果は、過去の書込み成功の証拠とは分ける。

## 未知サイズの容量計上

既知の正サイズはfullUpfront、サイズ未指定はincrementalをRustが指定する。不正なサイズ値は拒否する。有限上限M、最低空き容量H、同一資産・測定・期限・更新契約は変えない。

incrementalは最初の1 allocation unit以下から始め、各書込み前に同じボリュームの空き容量と他の未割当claimを確認する。ロック内で書込み前にclaimを保存し、部分書込みを含むI/O失敗後は再書込みを拒否する。失敗・完了後も未割当claimを所有者の正確な解放まで保持する。割当済みバイトは空き容量に反映されるため二重に差し引かない。

これは同一manager内の容量計上であり、OSによる予約や他プロセスの使用防止ではない。取得中の外部容量低下は失敗になり得る。

## 原本アクセスの制約

実Immich 3.3.3では、独立動画のlocked後の通常detail/originalは400/404だった。一方、写真とnative CIDで関連する動画では、locked/relocked後も共有キー・昇格sessionなしの通常owner APIがdetail/originalを200で返し、原本バイトも一致した。

確認画面は、既存共有リンクと関連写真・動画経由の原本アクセスが継続し得ること、関連項目の表示先を変えないこと、アルバム所属が自動復元されないことを説明する。選択行のlocked成功を、全経路での原本アクセス遮断と説明しない。観測窓内のqueue不変も、将来の全処理の保証ではない。

## 最終ローカル検証

製品・テストsource `0537f5f309053231ee312710f6b97cffca4956361fdf483fe8290143de221a2c`で以下を実行した。通常文字サイズの確認画面1枚をレビュー後に更新したsourceは`4f20f995d1454017e61ebfdb693d1f3bcf90586f60de818f6fb0c22d8df3dbdc`。他49基準と非baselineソースは不変で、strictは更新後sourceを対象にした。

記録は検証worktreeの`.tools/verification/`以下。

| 検証 | 結果 | result.jsonの親ディレクトリ |
| --- | --- | --- |
| make check | Rust467／Swift70／infra24成功、121.88秒 | video-visibility-incremental-check-20261016-2-03xh8v2s |
| focused native | 40成功、失敗0、skip0 | video-visibility-incremental-native-20261016-1-bzlj5o6d |
| 全Apple build | 当時の5 Rust release構成、XCFramework、iOS／macOS成功、7889.02秒 | video-visibility-incremental-apple-full-20261016-1-reabhm5a |
| Mac native | 9成功、失敗0、skip0 | incremental-mac-native-20261017-1-knyojjft |
| 実Immich 3.2.4 | 14成功、失敗0、ignored0（適用外7） | incremental-real324-20261017-1-vqc7mk_s |
| 実Immich 3.3.3 | 15成功、失敗0、ignored0（適用外6） | incremental-real333-20261017-1-t9ngor5r |
| strict VRT | host168＋UI61＝229成功、失敗0、skip0、2918.8秒 | incremental-strict-20261017-1-y6oa67cn |

全実行のsourceは各前後不変。実サーバーの隔離container・volume・networkは終了後に削除した。strictの`DerivedData/VRTArtifacts/20261016T165935Z-5523/Tests.xcresult`で実件数を確認し、全50画面、差分0、record=false、基準画像前後不変を確認した。通常・AX3で実動画の再生・停止・閉じる操作、動画の確認キャンセル・ロック・明示的な表示先選択・応答消失を検証した。AX3はスクロール表示であり全文が一画面に収まるとは主張しない。

独立ソースレビューでも追加の具体的指摘なし。ソースレビューと実行結果は別の証拠である。XcodeのSimulator診断収集のsimctlエラー72は保持するが、229件のテスト結果とは区別する。

## 失敗履歴と未確定事項

- 初回focused nativeはunlink失敗注入の1件が失敗。親namespaceだけを書込み不可にしていた注入をpayload leaseディレクトリへ修正し、対象再検証後に最終40件も成功した。
- 初回strictは219件中215成功・4失敗・skip0。旧VIDEO拒否期待、通常確認画面の意図した差分、未知サイズ取得のapproval段階の失敗を記録した。期待値を対応契約へ合わせ、確認画像はレビュー後に1枚だけ更新した。
- 容量測定注入で、未知サイズ上限を全額計上する従来方式がquote後の1 unitの容量低下でも拒否する機序を再現した。incrementalへの変更理由であるが、初回strict失敗の原因を証明したとは扱わない。
- DTO生成は必要なenumとfieldを変更したためwrapperのsource_changedをテスト成功として数えない。初回checkの101/100行制限失敗はhelper抽出後に解消し、最終checkが成功した。
- 先行PR #36は提出HEAD `f34a85a`のCI全11 job成功後にmain `3c23ca5`へマージされた。同一treeの[merge後CI 38887593424](https://github.com/rabe1028/suwop/actions/runs/38887593424)ではabsent-size playbackの数値generationをBoolとして扱うDecodingErrorで1件失敗（203成功／1失敗／skip0）。他9 jobは成功し、VRTと集約jobが失敗した。原因は未確定。stage・effect種別・generation型の診断と2048回のround-tripテストを追加したが、再現・原因解決とは扱わない。製品JSONデコード処理は変更していない。

履歴を同一treeの`3c23ca5`へ整合した際、600ファイル・未追跡11ファイル・index・差分・既存stashの保持を確認した。上記はPR #37のARM64ビルド変更を取り込む前のローカル証拠であり、その統合後の確認、提出HEADのCI、レビュー、マージは別途記録する。

実機・iCloud・実Face ID／Touch ID、Live複数資源処理、PP-03〜16はこの変更のローカル成功で完了扱いにしない。

## PR #37統合後の検証

ARM64ビルド構成を取り込んだHEAD `a3bd6a9191a65db5daf8b2f90e50bab1a7543005`、source `b403e453880f36180e16f1b23a29edfb7f0abafe3e4f92e4282fbb4a9a2f4513`で再確認した。統合によるApp／Sources／Tests／NativeAcceptance／VRT／crates／Cargo.toml／Cargo.lockの差分はない。

| 検証 | 結果 | result.jsonの親ディレクトリ |
| --- | --- | --- |
| make check | Rust467／Swift70／infra24成功 | video-visibility-pr37-check-20261017-1-t633lips |
| make apple-build | ARM64 macOS／iOS／Simulatorの3 release、XCFramework、両アプリ成功、4907.03秒 | video-visibility-pr37-apple-full-20261017-1-jh2n2bt5 |
| Mac native | 9成功、失敗0、47.1秒 | video-visibility-pr37-mac-native-20261017-1-7b2mvy3a |
| strict VRT | 229成功、失敗0、skip0、2907.87秒 | video-visibility-pr37-strict-20261017-1-q51sjzpn |

すべて検証前後のsourceは一致。strictの`DerivedData/VRTArtifacts/20261016T193043Z-75745/Tests.xcresult`から実件数を確認した。50画面のcoverage検査成功、比較成功、record=false、基準50枚の前後hash不変。ホスト168件とUI61件を含む。選択VIDEOの通常／AX3操作、Timelineの明示選択、応答消失後の再送防止も成功した。

実Immichの14／15件は上記の統合前の実行記録であり、今回再実行したとは記載しない。製品・fixtureソースが統合で変わらないことを確認している。提出HEADのCI・レビュー・マージ結果はローカル検証とは別に確認する。
