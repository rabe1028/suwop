# Immich VIDEO / Live 関連グラフの契約検証

PP-02の後続検証。固定Immich v3.2.4の隔離環境で実行する。
この増分は実APIの契約テストであり、製品のVIDEO / Live変更対応を有効にしたものではない。
Apple撮影Live Photoのメタデータ、PhotoKit保存、実機再生の証拠でもない。

## 試料と検証範囲

独自生成のH.264動画V/M各1,522 bytesと既存の異なるPNG P/P2/Qを使用する。
Vは独立動画、PとP2は同じMをlivePhotoVideoIdで参照し、P/Qはstackを構成する。
生成条件・hash・形式は `crates/suwop-core/tests/fixtures/live_graph/` に保持する。
全5原本のバイト、各resourceのowner/type/checksum/forward link/revision/visibility、
既知の所有アルバムへの所属を操作の前後で検査する。

## 実APIで観測した結果

- 同じMを参照するP/P2の作成は受理された。Mはhiddenへ変更された。
- Vの通常archive往復とPだけの通常archive往復は、既知の2所有アルバムと原本を保持した。
  Pの変更でMのhiddenは変わらなかった。
- Pだけをlockedへ変更するとPは通常権限の詳細取得で400となる一方、
  Mはhiddenのままで、通常権限の原本取得は200・元バイト一致だった。
  親だけのロックをLive全体の保護成功とは扱えない。
- P/Mを明示したbulk変更は両方をlockedにしたが、もう一方の親P2はtimelineのままだった。
  この結果を関連全体の自動展開や原子的変更の保証とは扱わない。
- Pをtimeline、Mをarchiveへ明示的に戻す別々の変更が可能だった。
  locked変更で失われた既知アルバム所属は自動復元されなかった。
- 通常APIキーでlockedを含む検索filterを要求すると401になる。
  許可されたtimeline/archive/hidden検索ではロックされたPが出ず、PIN権限の4種検索では出た。
  拒否された検索を空の検索結果とは扱わない。

権限不足の詳細取得400は固定版 `server/src/utils/access.ts` のrequireAccessと整合する。
同じ正しいIDの通常権限による変更前200とPIN権限による変更後の詳細も検査する。
検索filterの昇格要否は `server/src/utils/search-filter.ts` に基づく。

## 検証記録

初回は詳細取得403というfixtureの誤った期待で失敗、2回目は通常検索にもlockedを含めたため401で失敗。
各回とも既存4シナリオは成功。契約に沿ってfixtureを修正した3回目は全5シナリオ成功。
`/tmp/suwop-live-graph-integration-20261015-3.log`、
`/tmp/suwop-live-graph-api-report-20261015-3.json` に12段階の観測を保持する。
通常権限のM原本取得200を固定assertへ追加した最終ソースでも全5シナリオが成功した
（`/tmp/suwop-live-graph-integration-20261015-4.log`、24.89秒）。
API観測は `/tmp/suwop-live-graph-api-report-20261015-4.json` に保持する。

`scripts/live-graph-readonly.py` はDBへ接続せず、ownerを限定した静的SQLの出力と結果照合を行う。
隔離DBでBEGIN READ ONLY・5秒のstatement timeout付きクエリを実行し、
Mの逆参照が正確にP/P2の2件、Vの逆参照0件、親のIMAGE型、M/Vのforward null、
APIとDBの最終visibility一致を確認した。
`/tmp/suwop-live-graph-readonly-query-20261015-3a.sql`、
`/tmp/suwop-live-graph-readonly-rows-20261015-3a.json`、
`/tmp/suwop-live-graph-readonly-control-20261015-3a.json` に記録する。
最終ソースの4回目でも同じ照合が成功した
（`/tmp/suwop-live-graph-readonly-control-20261015-4.json`、同名query/rowsを保持）。
専用projectのコンテナ・volumeは各照合後に削除した。
最終 `make check` はRust316件（実環境用5件はignored）・Swift65件とlint・生成確認が成功した
（`/tmp/suwop-live-graph-check-20261015-1.log`）。製品コード・DTO・基準画像に変更はなく、
この増分でAppleビルド・VRTは再実行していない。hosted CIは別途確認する。

## 製品対応へ引き継ぐ条件

通常archiveとPIN保護は異なる操作として設計する。保護操作では付随動画と複数親への影響を
確認画面・記録・照合へ含める。対象ごとの旧状態と部分的な結果を保持し、応答喪失を自動再送しない。
一つの動画を共有する別の親が保護されている場合、解除がその保護を破らない方針を決める。

今回のDB照合は既知の隔離fixtureの同一時点の証拠であり、製品の公開API認可ではない。
通常検索から逆参照が見つからないことを、ロックされた親も含めた不存在証明にしない。
一方、同時変更が完全に排除されないことだけを理由に製品対応を無期限に棚上げせず、
利用者に必要な操作単位と公開APIの実際の保証に基づいて対応範囲・再照合・部分失敗処理を設計する。
VIDEO / Live対応、異常系、実撮影ペアのnative受入れは引き続き未完了である。
