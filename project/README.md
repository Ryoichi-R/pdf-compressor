# pdf-compressor

保存用途で PDF の容量を削減するスタンドアロンツール。
Ghostscript / qpdf / Poppler を PowerShell から駆動し、PDF 内容を解析して
圧縮候補を生成する。候補は `_work` 上で構文・ページ構造を検証してから正式出力へ移す。

ローカル処理専用で、テレメトリー、クラウド送信、PDF本文の外部送信は行わない。

読み書きはプロジェクトルート配下に限定する（`_internal/path-guard.ps1`）。
親ディレクトリや隣接ディレクトリのファイル、依存、PATH は共有も変更もしない。

## 利用者向け導入

GitHub Releaseの`pdf-compressor-win-x64.zip`を任意のローカルフォルダーへすべて展開し、
`PdfCompressor.App.exe`（GUI）または`compress.bat`（CLI）を起動する。
x64 payloadにはPowerShell 7、Ghostscript、qpdf、Popplerを同梱しているため、
利用者PCへのSDK、compiler、winget、管理者権限は不要である。
公開するRelease ZIPはnative ARM64 payloadを提供しない。ARM64 hostではwin-x64 payloadを
Windows標準のx64エミュレーション上で実行する。

repository直下の`ここから開始 - PDF Compressorを導入・更新.bat`は、検証済みpayloadを
`installer/payload/`へ配置した保守・canonical package作成用である。ignore対象のpayloadを含まない
GitHubのsource ZIPまたはclone単体では使用しない。

native ARM64 payloadの技術検証の状況と未完了項目は[CHANGELOG.md](CHANGELOG.md)に、
依存の provenance と gate 判定は[installer/DEPENDENCY-AUDIT.md](installer/DEPENDENCY-AUDIT.md)に記載する。

更新は同じBATを使用し、前版markerに記録されたmanaged filesだけを置換する。
`output`、AppData設定、利用者追加ファイルは保持される。実行中は更新をexit 8で拒否する。

Release ZIP版のアンインストールは、必要な出力PDFを退避してから展開先フォルダーを削除する。
入口BATで作成したcanonical packageを使用した場合は、導入先の`PDF Compressor`フォルダーを削除する。
完全削除する場合は、必要な出力を退避したうえで
`%APPDATA%\pdf-compressor`（設定）と
`%LOCALAPPDATA%\pdf-compressor`（更新state・backup）も手動削除する。

installerはmanaged file変更前に、fresh=`2Enew+H`、update=`Enew+Ecurrent+H`
（`H=max(256MiB, ceil(Enew*0.10))`）の空き容量を検査する。一世代保持の削除候補は
更新成功後に診断する。既存backupは既定では削除せず、installerへ
`-ApproveBackupRetentionCleanup`を明示した更新だけが、安全検証後に一世代を超えるbackupを削除する。

## ライセンス

Copyright (c) 2026 Ryoichi-R

```
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
```

本ソフトウェアはローカル処理専用であり、ネットワーク越しに利用者へサービスを提供しない。
そのため AGPL-3.0 第13条（ネットワーク経由の利用者に対する対応ソース提供）は実質的に発動しないが、
配布物を第三者へ引き渡す場合は第6条の対応ソース提供義務が適用される。

ライセンス、第三者通知、対応ソースの取得方法は`LICENSE`、`THIRD-PARTY-NOTICES.md`、
`licenses\`、`third-party-source\README.md`を参照する。上流アーカイブはGit履歴へ含めず、
バイナリ配布時は同じバージョンの`pdf-compressor-corresponding-source-win-x64.zip`を
GitHub Release assetとして併載する。

### コード署名の状態

`PdfCompressor.App.exe`、installer script、candidate builder scriptはいずれも
**未署名（NotSigned）**である。D-14によりcode signingはDEFERREDであり、
署名鍵の調達・保管・更新責任が成立するまで署名は行わない。

- 初回起動時にWindows SmartScreenの警告が出る場合がある。
- 完全性の確認は、配布物へ併記するSHA-256との照合で行う。
- 署名を後から導入する場合、manifest v2のPE検証とG4 gateが変わるため
  candidateの再生成が必須である。既存candidateへ後付けで署名しない。

### 既知の制限

- **アクセシビリティは未検証である。** キーボード操作だけでGUIを完結できるか、および
  スクリーンリーダーでの読み上げは、受入試験の対象外としている（owner判断による明示的な
  DEFER）。該当する操作が必要な場合はCLI（`compress.bat`）を使用する。
- 配布はWindows x64のみである。macOSとLinuxには対応しない。
- OCRは任意機能であり、providerを同梱しない。`-EnableOcr`はOCRmyPDFが別途導入されている
  環境でのみ動作する。
- `-TargetBytes`は保証値ではなく目標値である。

## source checkoutの必要環境

- Windows 10 / 11
- **PowerShell 7+ (`pwsh`) 必須**（Windows PowerShell 5.1 は非対応）
  - 未導入の場合: `winget install --id Microsoft.PowerShell`
- 開発用BATは`project\scripts\launchers\`と`project\scripts\setup\`にある
- winget（qpdf / Poppler 導入用。Ghostscript は公式ページから手動導入）

Ghostscript（AGPL/commercial）、qpdf（Apache-2.0）、Poppler（GPL 系）の配布・利用条件は、
使用する配布物の公式ライセンスを確認すること。OCR を使う場合は OCRmyPDF / Tesseract の
ライセンスと追加依存も別途確認する。OCR は任意機能で、base compression の必須依存ではない。

## セットアップ

```cmd
scripts\setup\install-dependencies.bat
```

以下を導入する:

| ツール      | パッケージ ID                         | 用途                                   |
| ----------- | ------------------------------------- | -------------------------------------- |
| Ghostscript | winget ではなく公式ページから手動導入 | PDF 再生成・画像ダウンサンプリング     |
| qpdf        | `QPDF.QPDF`                           | 構造最適化・オブジェクトストリーム化   |
| Poppler     | `oschwartz10612.Poppler`              | PDF 内容解析（`pdfinfo`, `pdfimages`） |

Ghostscript の手動 DL リンク、または winget が使えない / 失敗した場合の手動 DL リンクを表示する。
source checkoutで解決したツールパスだけを `_internal/data/tool-paths.json` にキャッシュする。
installed modeはこのcacheを読み書きせず、同梱ツールだけを使用する。

## 使い方

### 単一ファイル

```cmd
scripts\launchers\compress-dev.bat "C:\path\to\file.pdf"
```

### フォルダ一括（再帰）

```cmd
scripts\launchers\compress-dev.bat "C:\path\to\folder"
```

配下の `*.pdf` を再帰処理。`*.compressed.pdf` と
`<toolroot>\output\` 配下は再処理対象から除外。

### ドラッグ&ドロップ

`scripts\launchers\compress-dev.bat` に PDF ファイル / フォルダをドロップしても同じ挙動。

### 対話モード

引数なしで起動するとパス入力プロンプト。

### GUI モード

```cmd
scripts\launchers\gui.bat
```

WinForms 製の GUI が起動する。

- 入力フィールドにファイル / フォルダを D&D もしくは [参照] で指定
- 戦略は日本語の用途別ラベルから選択（既定は「自動（おすすめ）」）。内部的には従来どおり `auto` などの strategy id を使う
- 「最大圧縮・画像化（検索不可）」と「可読性優先・画像化（検索不可）」はページ全体を画像化する劣化圧縮。テキスト検索、コピー、リンク、フォーム、しおり等は失われる可能性があるため、GUIでは実行前に確認ダイアログを表示する
- [✓] 既存出力を上書き で `-Force` 相当
- 出力先フォルダは未指定なら `<toolroot>\output\` 既定。指定する場合は **ローカルドライブ（`C:\` / `D:\` 等）のみ**許可（UNC・`\\?\` 長パス・存在しないドライブは赤字表示で実行ブロック）
- 進捗バー、ログ表示、実測の圧縮率サマリ、[中止] ボタンに対応
- PDFファイルの複数選択、複数D&D、キューの状態表示、処理済み／総数表示に対応
- キューで1件以上を選び、[選択を削除]またはDeleteキーで入力を取り除ける。診断・圧縮中は実行中batchとの競合を避けるため削除を無効化する
- 入力追加後は短い遅延付きの圧縮前preflightを非同期実行し、検出機能、検証状態、理由、候補戦略をキューへ表示。不確実な検出がある場合は明示確認なしにRunできない
- 自動・高画質・標準・最小容量の4モード、Safe/Warn/Off、安全確認、目標bytesを指定可能
- 下部の[元PDFを開く]・[結果PDFを開く]でPDFを既定のビューアーに表示し、[元PDFの場所]・[結果PDFの場所]で対象ファイルをエクスプローラー上に選択表示できる。出力先[開く]は常に設定中の出力先フォルダーを開く
- 出力行の[診断]から独立した環境診断画面を開き、tool/version、Safe可否、書込みチェック、telemetry=noneを確認できる
- 設定（最終入力、出力先、戦略、モード、安全モード、目標値、上書き、ウィンドウサイズ／位置）は `%APPDATA%\pdf-compressor\settings.json` に永続化する。ただし署名許可、ページ全体ラスタ許可、manifest nonce は永続化しない

installed版の`compress.bat`とsource版の`scripts\launchers\compress-dev.bat`は、
従来のCLI引数・終了コード契約を維持する。

## 出力先

既定では `<toolroot>\output\<safe-relative-path>\<name>.compressed.pdf` 配下に保存される。
入力 PDF の場所にかかわらず、既定出力は実行中のツールディレクトリ配下に限定される
（workspace policy に基づく path-guard 強制）。

GUI または CLI `-OutputRoot <path>` で出力ルートを変更した場合は、その配下に
`<safe-relative-path>\<name>.compressed.pdf` で保存される（入力ルートからの相対構造を維持）。
`-OutputRoot` はローカルドライブ（`C:\`, `D:\` 等の単一ドライブレター）配下のみ許可。
UNC (`\\server\share\...`)・`\\?\` / `\\.\` 長パス・相対パス・未存在ドライブは拒否（exit 5）。

ログ: `<toolroot>\output\compress.log.jsonl`（JSON Lines）。
ログ位置は `-OutputRoot` の有無に関わらずツール配下固定。

## 戦略の自動判定

| GUI表示                        | strategy id             | 使う場面                                  | 説明                                        |
| ------------------------------ | ----------------------- | ----------------------------------------- | ------------------------------------------- |
| 自動（おすすめ）               | `auto`                  | 通常はこちら                              | PDF の内容を解析して下記から自動選択        |
| 無劣化（テキスト/図面向け）    | `qpdf-lossless`         | テキスト/ベクター主体（画像比率 < 30%）   | 無劣化                                      |
| 強く圧縮（高DPIスキャン向け）  | `gs-downsample-150`     | スキャン画像主体・高 DPI (≥ 220)          | DPI 150 にダウンサンプル                    |
| 最小容量候補                   | `gs-downsample-120`     | `-TargetBytes` または最小容量モード       | DPI 120 にダウンサンプル                    |
| バランス（文字+画像）          | `gs-downsample-180`     | 混在（画像比率 30-70%）                   | DPI 180 にダウンサンプル                    |
| 軽く再生成（低/中DPIスキャン） | `gs-light-regenerate`   | 画像主体・低/中 DPI                       | `qpdf-lossless` で効果がない場合の fallback |
| 最大圧縮・画像化（検索不可）   | `gs-raster-low-quality` | 通常圧縮で縮まない PDF を強く縮めたい場合 | 明示指定専用。120dpi / JPEG品質45           |
| 可読性優先・画像化（検索不可） | `gs-raster-readable`    | 画像化しつつ小さい文字を残したい場合      | 明示指定専用。220dpi / JPEG品質80           |

閾値・DPI は `_internal/data/strategies.json` に外出し（`strategies.schema.json` で型保証）。

`gs-raster-low-quality` と `gs-raster-readable` は自動判定では選ばれない。CLI の
`-StrategyOverride gs-raster-low-quality` / `-StrategyOverride gs-raster-readable` または GUI の戦略選択で明示指定した場合のみ使う。

`gs-raster-low-quality` は 120dpi / JPEG品質45 の最大圧縮寄りで、小さい文字はつぶれやすい。
小さい文字の可読性を残したい場合は、220dpi / JPEG品質80 の `gs-raster-readable` を使う。
Ghostscript `pdfimage24` によりページ全体を各戦略の `raster_dpi` で画像化するため、
通常のダウンサンプルで縮まない描画命令主体の PDF に有効な場合がある。

## 安全ポリシーと検証

- Safe（既定）は暗号化・電子署名付きPDFを処理せず SKIP とする。電子署名の存在は qpdf JSON、
  `pdfsig` 等で四状態（present / absent / indeterminate / unavailable）として扱い、検出不能を absent に置き換えない
- `-AllowSignedPdf` は明示的な再同意であり、署名を保持する機能ではない
- ページ全体ラスタ戦略は `-AllowFullPageRaster` がない限り実行しない。テキスト検索、リンク、フォーム、しおり、タグ等が失われる可能性がある
- `safety-policy.json` の `features.<name>.safe|warn|off` を実行判定と検証後の機能損失判定の正本にする。添付・しおり・リンク・PDF/A/X は Safe で保持必須、フォーム・JavaScript・タグ・レイヤー等は警告対象とする
- PDF/A/X を Ghostscript 再生成する候補は警告を記録し、前後の規格状態を必ず比較する。検証で失われた保持必須機能は Safe では採用しない
- `-SafetyMode Warn` / `Off` は検出不能や安全機能の扱いを緩和するため、ログの verification status と理由を確認する
- qpdf check、ページ数、MediaBox/CropBox、Rotate、検出した安全機能の比較に合格した候補だけを正式出力する。検証 reject の候補は出力せず、CLI/GUIへ具体的な検証理由を表示する
- 全面ラスタ戦略はページ端をdevice pixelへ量子化するため、Box比較に限り選択DPIの1 pixel（`72 / raster_dpi` pt）まで許容する。通常戦略は0.01ptのまま、大きなCropBox変更、ページ数・向きの変化は引き続き拒否する

## 目標容量とOCR

`-TargetBytes` は保証値ではなく目標値。最大7候補まで試し、目標以下の最高品質候補を採用する。
目標未達でも元より小さく検証済みの候補があれば `target_status=not-met` として保存し、終了コード6を返す。
有効候補がなければ正式出力しない。

OCR は `-EnableOcr -OcrLanguages jpn eng` で明示的に有効化する任意終端ステージ。OCR後もサイズ・qpdf・構造を再検証し、
OCR provider 不足は `ocr_status=skipped` として理由を残す。

## manifest / 複数入力

CLI の `-InputPath` は内部で1 item manifestへ変換される。複数入力や個別設定には `-InputManifest` を使う。
GUIが生成するmanifestは `_work\<run-id>\` 配下に置かれ、リスク同意には128-bit以上のrun nonce、
`-AcceptManifestRiskConsents`、manifest所在の3条件を要求する。手書きmanifestの true consent を暗黙受理しない。

```powershell
pwsh _internal\compress.ps1 -InputPath 'C:\docs' -Mode standard -SafetyMode Safe -TargetBytes 5000000 -StatusJson
pwsh _internal\compress.ps1 -InputManifest 'C:\path\input.manifest.json' -AcceptManifestRiskConsents -RiskConsentNonce '<run nonce>'
```

## ログ書式

```
[OK] sample.pdf  2.1 MB -> 1.2 MB  (-43%)  strategy=gs-downsample-150
[SKIP] already-small.pdf  320.0 KB -> 320.0 KB  no-effect
[FAIL] encrypted.pdf  tool=pdfimages fail_reason=encrypted
[SUMMARY] total=3 ok=1 skip=1 fail=1 skip_ratio=33%
```

サイズは `InvariantCulture`、桁区切りなし、1024 進。
GUI の圧縮率サマリは、処理に成功したファイルの `original` / `compressed` を合算した実測削減率を表示する。PDF の画像比率、DPI、内部構造で結果が変わるため、実行前の予測値は表示しない。

## 終了コード

| code | 意味                                                                                                  |
| ---- | ----------------------------------------------------------------------------------------------------- |
| 0    | 全件成功（`[SKIP] no-effect` を含む）                                                                 |
| 1    | 内部エラー（1 件以上 fail）                                                                           |
| 2    | 依存ツール未検出                                                                                      |
| 3    | 入力パス不正                                                                                          |
| 4    | 1 件以上が `[SKIP] exists`（出力既存・`--Force` なし）。`failN==0` 前提で発火、`okN` の有無は問わない |
| 5    | workspace policy 違反                                                                                 |
| 6    | safety policy の SKIP、target 未達、またはその他の operator action required                           |

終了コード6は失敗と同義ではない。per-file JSONL と `StatusJson` summary の `stop_reason`
（例: `safety-skip`, `target-not-met`）を確認する。優先順位は `fail(1) > exists(4) > action(6) > 0`。

## テスト

```powershell
pwsh _internal\run-tests.ps1
pwsh _internal\run-tests.ps1 -Suite E2E
pwsh _internal\run-tests.ps1 -Suite Unit -CodeCoverage
pwsh _internal\run-tests.ps1 -Suite E2E -AllowMissingExternalTools  # ローカル開発時のみ
pwsh _internal\diagnostics.ps1 -JsonOnly
pwsh ..\scripts\measure-pdf-compressor-baseline.ps1
```

Pester 5 必須。`tests\` 配下を再帰探索し、`*.Tests.ps1` を実行する。
引数なしは Unit、`-Suite Integration|E2E|All` を指定できる。E2E は qpdf / Ghostscript / Poppler と
fixture provenance が不足すると exit 2 で止まり、`-AllowMissingExternalTools` の場合だけ理由付きでskipする。
release証拠のstrict E2Eは、検証済みcandidateを空directoryへ展開し、
`PDF_COMPRESSOR_INSTALL_ROOT`でbundled toolだけを解決する。machine PATH依存結果はrelease証拠にしない。
Tier C0 coverage targetは`_internal/data/coverage-targets.json`の19 core filesに対して90%。
10 MiB / 50 page のpreflight＋post-validation baselineは、`tests\performance\Measure-PdfValidationBaseline.ps1`でwarm-up後5回以上を測定し、`result\pdf-compressor\performance-validation-baseline-*.json`へhost/toolchain付きで保存する。2026-08-12の現行baseline中央値は2,541.047 ms、同一host/toolchainでの次回上限は3,811.570 ms（1.5B）。Ghostscript戦略、queue規模、cancel、target-size資源量は別計測である。

## candidate build

`global.json`で.NET SDKを固定し、`installer\Build-Payload.ps1`はlauncherをsourceからclean publishする。
成果物は`installer\candidates\<run-id>`へ生成され、canonical `installer\payload`は変更しない。
legacy単一runtime candidateのmanifest v2はbuild ID、source/dependency/tree digest、SDK、tool version、PE architecture、archive hashを結合する。
新規単一runtime candidateと合成candidateはmanifest v3でruntime別provenanceを保持する。ARM64対応ソースsidecarは製品source、
qpdf／Poppler／Ghostscriptの固定source archive、build recipeをhash bindingする。candidate promotionは別の明示承認が必要。

## 設計詳細

`_internal/ARCHITECTURE.md` を参照。
