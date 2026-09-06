# pdf-compressor ARCHITECTURE

## 前提環境

PowerShell 7+ (`pwsh.exe`) が PATH 上に必須。`gui.bat` / `compress.bat` / `install.bat` は `where pwsh` 失敗で exit 2 する。Windows PowerShell 5.1 (`powershell.exe`) フォールバックは廃止（`ProcessStartInfo.ArgumentList` 不在、`Test-Json` 不在で機能不全になるため）。

## データフロー

```
compress.bat (drag-drop / interactive)         gui.bat
   |                                              |
   v                                              v
_internal/compress.ps1  (orchestrator) <-- child --  _internal/gui.ps1 (WinForms queue)
   |--> input-manifest.ps1             (path normalize / dedupe / item settings)
   |--> tool-capabilities.ps1          (required / optional / diagnostics)
   |--> path-guard.ps1                 (input / write / local-output guard)
   |--> Invoke-WorkDirCleanup          (TTL 24h on _work\)
   |
   v  (per PDF)
analyze_pdf.ps1   --> pdfinfo + pdfimages -list  --> metrics{ imageRatio, avgDpi, ... }
   |
   v
inspect_pdf_features.ps1 --> feature state{present|absent|indeterminate|unavailable}
   |                                |
   +--> safety-policy.ps1 -----------+--> Safe/Warn/Off decision
   v
select_strategy.ps1 / target-size.ps1 (data + capability) --> bounded candidates (max 7)
   |
   v
invoke_ghostscript.ps1 / invoke_qpdf.ps1 / invoke_lossy_raster.ps1
   |--> writes to _work\<pid>-<guid>\out.pdf
   |
   v
validate_output.ps1 --> qpdf check + page/box/rotate + feature comparison
   |---> reject / warning policy -> discard candidate in _work
   |---> accepted -> size/target decision -> move to formal output
   |
   v
log line (stdout) + JSON Lines (output\compress.log.jsonl)
```

## モジュール

| ファイル | 役割 |
|---|---|
| `compress.ps1` | エントリ。引数解析・依存解決・列挙・ループ・ログ・サマリ |
| `analyze_pdf.ps1` | `pdfinfo` + `pdfimages -list` 呼び出しとメトリクス計算 |
| `select_strategy.ps1` | 閾値判定 + DPI ホワイトリスト検証 |
| `invoke_ghostscript.ps1` | Ghostscript 引数組み立て（配列形式のみ） |
| `invoke_lossy_raster.ps1` | Ghostscript `pdfimage24` による明示選択専用の劣化ラスタ圧縮。ページ全体を低解像度画像化する |
| `invoke_qpdf.ps1` | qpdf 引数組み立て（`--linearize` は既定 off） |
| `path-guard.ps1` | 入力PDFの存在・拡張子・絶対パス検査、書込先境界判定。既存祖先の reparse point は拒否し、暗黙追従しない |
| `output-path.ps1` | item-scopedな出力context、由来ID、相対パス、sanitize、衝突回避 |
| `input-manifest.ps1` | 複数入力、重複排除、item override、risk consent run binding |
| `tool-capabilities.ps1` | required/optional tool、version、safe-ready、strategy capability |
| `diagnostics.ps1` | 外部依存、書込先、telemetryなしをJSONで自己診断。GUIの独立診断画面からも同じ関数を利用 |
| `inspect_pdf_features.ps1` | PDF/A/X、署名、暗号化、フォーム等の四状態検出 |
| `safety-policy.ps1` | `safety-policy.json` の feature action、Safe/Warn/Off、署名既定SKIP、ラスタ明示同意、PDF/A/X再生成警告、検出不能処理 |
| `pdf-structure.ps1` | ページ数、MediaBox/CropBox、Rotateの正規化snapshot |
| `validate_output.ps1` | qpdf check、warning正規化、構造・安全機能比較 |
| `tests/support/New-SyntheticPdf.ps1` | text、画像XObject、AcroForm、添付、outline、link、page別Rotate/CropBoxを生成する合法な実PDF fixture factory |
| `tests/performance/Measure-PdfValidationBaseline.ps1` | 10 MiB / 50 pageのpreflight＋post-validationをwarm-up後5回以上測定し、同一host/toolchain用のBと1.5Bを記録 |
| `target-size.ps1` | 目標容量候補、品質順位、最大7試行、未達結果 |
| `ocr-provider.ps1` | OCRmyPDF capability、言語検査、任意実行、再検証入口 |
| `gui-queue.ps1` | GUI item、状態遷移、重複排除、Run gate |
| `gui.ps1` | WinForms GUI。`compress.ps1` を `-StatusJson` 子プロセス起動し、stdout の `##STATUS##` JSON を進捗バー・ログ・サマリに反映。出力先チェックは UX hint のみで、境界判定の正本は子プロセス側 `compress.ps1` の path-guard。`gs-raster-*` 劣化戦略は実行前に確認ダイアログを表示。元PDF／結果PDFは既定のビューアーで開く操作とエクスプローラー上で選択表示する操作を分離し、出力先の[開く]は常に設定中のフォルダーを開く。診断ボタンは CLI の `Get-PdfCompressorDiagnostics` を利用した独立画面を表示する。中止時はowned cancel markerで5秒の協調停止を待ち、期限超過時だけ`Process.Kill(true)`、さらに失敗時だけ`taskkill /T /F`へfallbackする。UTF-8 BOM 付き保存（PS 5.1 mojibake 回避） |
| `gui-settings.ps1` | `%APPDATA%\pdf-compressor\settings.json` のロード／セーブ。version 非互換・JSON 破損時は既定値に復帰 |
| `setup-dependencies.ps1` | winget 導入 + `tool-paths.json` 生成（手動 DL フォールバック） |
| `data/strategies.json` | 閾値・DPI 正本 |
| `data/strategies.schema.json` | JSON Schema 検証（`strategy_id` enum） |
| `data/tool-paths.json` | 解決済みツールパスキャッシュ（自己修復） |

## path-guard 境界判定アルゴリズム

1. `\\?\` / `\\.\` / `\\` で始まるパスは即拒否（UNC・長パス禁止）。
2. パスを末端から親へ遡り、最初に実在するディレクトリを探す。
3. 実在する各祖先に `Get-Item -Force` を当て、ReparsePoint があれば拒否する。
   既存のjunction / symlinkを暗黙に追従しないため、書込のTOCTOU窓を狭める。
4. 未作成セグメントを `Join-Path` で再結合し、
   `[System.IO.Path]::GetFullPath()` で正規化。
5. `path-guard.ps1` 自身の配置から導出した `<toolroot>\` で前方一致するか
   `ToLowerInvariant()` 比較で確認。インストール先の絶対パスは固定しない。
   外れていれば `throw`、呼び出し側は exit code 5。

## `Assert-OutputPathLocal` 境界判定アルゴリズム

GUI / CLI の `-OutputRoot` で外部ドライブを出力先に指定する場合の境界:

1. `\\?\` / `\\.\` / `\\` で始まるパスは即拒否（UNC・device/長パス禁止）。
2. 相対パスは拒否。
3. `[System.IO.Path]::GetPathRoot()` が `^[A-Za-z]:\\$`（単一ドライブレター）であることを確認。
4. ドライブ root が実在することを確認（`Test-Path -LiteralPath`）。
5. 未作成末尾セグメントは既存祖先を辿り再構成して `[System.IO.Path]::GetFullPath()` で正規化。
6. 既存祖先のシンボリックリンク / ジャンクションは拒否する。意図した配置は、利用者が事前に解決した実体パスで指定する。

`_work\`・`compress.log.jsonl`・`data\tool-paths.json` は引き続き `Assert-WritePathInsideTool` でツール配下固定。
`-OutputRoot` は出力 PDF のルートだけを切り替える。

## GUI 経路の子プロセス通信プロトコル

`compress.ps1 -StatusJson` 指定時は通常の人間可読 stdout に加え、`##STATUS## {json}` を 1 行で出力する:

```
##STATUS## {"event":"start","total":N}
##STATUS## {"event":"file","idx":I,"file":"...","status":"ok|skip|fail","strategy_id":"...","original":N,"compressed":N,"ratio_pct":I,"fail_reason":"...","tool":"..."}
##STATUS## {"event":"summary","total":N,"ok":A,"skip":B,"fail":C,"skip_ratio":P}
```

GUI 側は `Process.OutputDataReceived` / `ErrorDataReceived` を `Register-ObjectEvent` で受信するが、Action scriptblock は event sink runspace で評価されるため、スクリプトスコープ関数 (`Receive-StdoutLine` / `Write-LogUI` / `Invoke-StatusLine`) は解決できない。よって Action 内では `MessageData` 経由で渡された `ConcurrentQueue[string]` への `Enqueue` のみを行い、`btnRun.Add_Click` のメインループ (`DoEvents` ループ) が `Receive-OutputQueues` で逐次 dequeue → `Receive-StdoutLine` 呼び出しを行う。これにより関数解決はメインスレッドの正規スコープで安全に走る。

中止 (`Invoke-Cancel`) では以下の順序を厳守する:

1. `_work\cancel-<pid>-<guid>.request`をatomic作成して協調停止を要求
2. 最大5秒、stdout/stderrをdrainしながら終了を待つ
3. 期限超過時だけ`Process.Kill(true)`、さらに3秒後も残る場合だけ`taskkill /T /F`へfallback
4. `WaitForExit()`で非同期stdout/stderrのflushを待ち、`Receive-OutputQueues`で末尾statusを反映
5. forced fallback有無をlogへ残し、`Write-AbortedJsonl`でaborted行を追記
6. owned workとcancel markerを片付け、`Clear-OutputEventBridge`でsubscription/job/queueを解放

`btnRun.Add_Click` は `try { ... } catch { ... } finally { Clear-OutputEventBridge; Set-UIEnabled $true; ... }` 構造で、`DoEvents` / `WaitForExit` 中の例外でも UI 永続無効化と subscription/Job リークが起きない。`Start-CompressJob` も `Register-ObjectEvent` 成功後の `Start()` 失敗を `try/catch` で受け、`Clear-OutputEventBridge` 後に再 throw する。

子プロセスは UTF-8 ストリームで通信:

- `ProcessStartInfo.StandardOutputEncoding` / `StandardErrorEncoding` を `UTF8` 固定
- `CreateNoWindow = $true`、`WindowStyle = Hidden` で CMD / PS のちらつき防止
- C# launcherも`WinExe`に加えて、bundled PowerShellの`ProcessStartInfo`へ`CreateNoWindow = true`と`WindowStyle = Hidden`を指定する
- `pwsh.exe` を `Get-Command pwsh` で解決。**`pwsh` 必須**（不在時は throw）。`powershell.exe` (Windows PowerShell 5.1) へのフォールバックは廃止

CLIは`-CancelFile`をowned work root配下に限定し、item間・candidate開始前に加えて外部tool終了直後と正式出力commit直前にもmarkerを検出する。これにより外部tool実行中の中止要求が、その終了後に検証・commitへ進むraceを防ぐ。外部toolが応答しない場合はGUI側の5秒grace後にowned process treeを強制停止する。forced fallback理由をGUI logへ残し、`compress.log.jsonl`には`{"status":"fail","fail_reason":"aborted","tool":"gui",...}`を1件追記する。

`event` は既存の `start` / `file` / `summary` を維持し、`queue`、`analysis`、`diagnostic`、`verification`
を追加する。未知eventを無視できるconsumerを前提に、`file` とJSONLの両方へ `item_id`、
`verification_status`、`target_status`（`not-requested|met|not-met|no-valid-candidate`）、互換用の`target_met`、`stop_reason`、`ocr_status` を出力する。summaryには停止理由別件数を含める。

## 安全・target・OCR

- すべての候補は正式出力前に `_work` で検証する。検証をバイパスする正式経路はない。
- `file` eventとCLI失敗行は`verification_reasons`を保持・表示し、GUIは共有診断messageへ変換する。
- signed / encryptedは検出器の unavailable と absent を区別し、Safeでは安全側にSKIPまたは実行不能とする。
- GUIのrisk consentは同一runのnonce、`-AcceptManifestRiskConsents`、`_work\<run-id>\`所在で束縛する。
- target指定時だけ最大7候補を生成する。通常targetなしは原則1候補で、no-effectはexit 0。
- OCRは任意の終端処理で、OCR後にサイズ、qpdf、構造を再検証する。
- 外部PDF本文・ログ・環境変数全体は外部へ送信しない。診断JSONのtelemetryは`none`固定。

## 出力パス生成規則

入力 PDF → 出力パスへの写像は出力先指定の有無で分岐する:

### A. デフォルト出力先 (`<toolroot>\output\`)

複数ドライブ・複数ルートからの収集を 1 つの output 直下で衝突なく堆積させるため、由来情報を含む構造を採用:

1. `Resolve-Path -LiteralPath` で正規化、`FileInfo.DirectoryName` を親ディレクトリ正本に。
2. 由来識別子:
   - ローカルドライブ: `drive-<letter>-<hash12>`（`hash12` = SHA-256 先頭 12 hex of drive root lowercased）
   - UNC: `unc-<hash12>`（`hash12` = SHA-256 先頭 12 hex of `\\server\share` lowercased）
3. 親ディレクトリは drive root / share 部分を除いた相対パスを `\` 区切りで保持。
   各セグメントは Windows 禁止文字 `< > : " / \ | ? *` と制御文字を `_` に置換、
   末尾の空白・ピリオドを除去、予約名（`CON`, `PRN`, ...）は末尾に `_`、
   `.` / `..` / 空セグメントは `_` に置換。
4. 最終形 `output\<origin-id>\<sanitized-parent-path>\<name>.compressed.pdf` を
   `Assert-WritePathInsideTool` に通す。境界外なら exit 5。

### B. 明示 `-OutputRoot` 指定時

ユーザが GUI / CLI で出力先を指定した場合は「指定フォルダ直下に置く」期待を優先し、由来 ID を付けず **入力ルートからの相対パスのみ** をミラーする:

1. 入力ルートを、入力がフォルダなら入力フォルダ自身、入力がファイルなら親ディレクトリとして item 単位の出力コンテキストに確立する。
2. 各 PDF について `FileInfo.DirectoryName` と入力ルートの差分を相対パスとして取り出す。差分なし（PDF が入力ルート直下）なら空文字。
3. 相対パスの各セグメントを A.3 と同じサニタイズ規則で処理。
4. 最終形 `<OutputRoot>\<sanitized-relative-dir>\<name>.compressed.pdf` を
   `Assert-OutputPathLocal` に通す。

例: 入力 `C:\src\foo`、出力 `D:\out`
- `C:\src\foo\a.pdf` → `D:\out\a.compressed.pdf`
- `C:\src\foo\sub\b.pdf` → `D:\out\sub\b.compressed.pdf`

## 終了コード規約

| code | 発生条件 | 復旧 |
|---|---|---|
| 0 | 全件成功（`[SKIP] no-effect` を含む。`[SKIP] exists` は含まない） | - |
| 1 | 1 件以上 fail、または DPI 検証・JSON 不正等の内部エラー | ログ確認 |
| 2 | 依存ツール未検出 | `install.bat` |
| 3 | 入力パス不正（PDF 以外・存在しない） | パス確認 |
| 4 | 1 件以上が `[SKIP] exists`（出力既存・`--Force` なし）。`failN==0` 前提で発火、`okN` の有無は問わない | `-Force` 付加 |
| 5 | path-guard 違反（境界外書込／UNC／長パス） | バグ／設定ミス（防御コード） |
| 6 | safety SKIP、target未達など operator action required | per-fileの`stop_reason`を確認 |

優先順位は `failN>0 → 1` > `existsN>0 && !Force → 4` > `action_required → 6` > `0`。
`[SKIP] no-effect` は per-file status であり exit code には影響しない（exit 0）。
`[SKIP] exists` は `--Force` 未指定時に exit 4 を発火させる（自動化スクリプトが `--Force` 忘れを検出できるよう、`okN` 混在ケースでも exit 4 とする）。

## `_work\` ディレクトリ規約

- 各ファイル処理ごとに `_work\<pid>-<guid>\` を作成し、完了時（成功/失敗/SKIP）に削除。
- 並行実行衝突は PID + GUID で回避。
- プロセス異常終了時の残骸は次回起動時に TTL 24h で掃除。

## 障害時クリーンアップ

| 障害 | 動作 |
|---|---|
| Ghostscript/qpdf 異常終了 | `_work\` 削除、`output\` には半端な `.compressed.pdf` を残さない（一時名 `out.pdf` で書き、成功時のみ rename） |
| `[SKIP] no-effect` | 試行した一時出力と `_work\` を削除、元 PDF はそのまま |
| プロセス強制終了 | 次回起動時 TTL 24h で `_work\` 配下を掃除 |
| `--Force` 上書き失敗 | `output-transaction.ps1`がwrite-through journalを先行作成し、backup→candidate promotion→commitを記録する。同一process失敗は巻き戻す |
| `--Force` 中のprocess crash | 次回同一output解決時、正規化済み同一directory・規定名・非reparseのbackupだけを対象に、output不在・backup存在の場合だけ自動復元する。その他の状態や改ざんjournalは`recovery-needed`で停止し、自動削除しない |

## 引数受け渡しとインジェクション対策

- `& $exe @args` 形式の配列引数のみ使用。文字列補間および `Invoke-Expression` は禁止。
- DPI 値は `[int]` キャスト + 範囲 (72-600) + ホワイトリスト（`{72,96,120,150,180,220,300}`）で検証。
- 全外部 CLI は `--` を引数末尾セパレータとして使用し、ファイルパスを option 扱いされないようにする。
- `cmd /c` 経由は禁止。

## 劣化ラスタ圧縮

`gs-raster-low-quality` と `gs-raster-readable` は `auto` では選ばれない明示指定専用戦略である。
`data/strategies.json` では `tool = lossy-raster` とし、最大圧縮寄りの `gs-raster-low-quality` は `raster_dpi = 120`、`jpeg_quality = 45`、小さい文字の可読性寄りの `gs-raster-readable` は `raster_dpi = 220`、`jpeg_quality = 80` を持つ。
実装は Ghostscript `pdfimage24` デバイスを使い、ページ全体をラスタ画像としてPDFへ再生成する。

`pdfimage24`はpage edgeをdevice pixelへ量子化する。したがって、この分岐だけは構造Boxの許容差を
`72 / raster_dpi` pt（最大1 pixel）に設定する。通常候補は0.01ptの厳格比較を維持し、ページ数、Rotate、
または1 pixelを超えるMediaBox/CropBox差は拒否する。

これらの戦略は検索可能テキスト、ベクター情報、リンク、フォーム、タグ、しおり等を保持しない可能性が高い。
通常の `ghostscript` 戦略とは別の `lossy-raster` 分岐にして、誤って自動選択されないようにする。
`StrategyOverride` 指定時は `compress.ps1` が fallback を `$null` にするため、これらの戦略の `fallback` は `null` とする。

`jpeg_quality` は Ghostscript へ `-dJPEGQ=<value>` として渡すが、環境やデバイスにより容量への寄与が小さい場合がある。
容量制御の主軸は `raster_dpi` であり、範囲は `72..300` とする。既存画像ダウンサンプル用の `allowed_dpi`
whitelist とは意味が異なるため、`raster_dpi` は schema と `invoke_lossy_raster.ps1` で独立検証する。

## 隣接ディレクトリとの非干渉

pdf-compressor はプロジェクトルート配下だけを読み書きする。親ディレクトリや
兄弟ディレクトリのファイル・依存・PATH は共有も変更もしない。

境界の機械的検証:

- `_internal/path-guard.ps1` の `Assert-WritePathInsideTool` がツールルート外への
  書き込みを拒否する。`tests/unit/path-guard.Tests.ps1` が兄弟ディレクトリ、
  UNC、`\\?\` 長パス、相対パス、空パスの拒否を検証する。
- 変更作業全体の非干渉証跡は、対象外ディレクトリの事前・事後 filesystem
  snapshot/hash で確認する。

> 2026-09-04: 特定の兄弟プロジェクト名を直接参照していた
> `tests/unit/non_interference.Tests.ps1` は削除した。単独リポジトリとして公開する
> 方針（一般公開 master plan の O-2）では検証対象の兄弟が存在せず、常に Skip する
> fail-open なテストになるため。境界検証の正本は上記 path-guard に一本化した。

## テスト方針

| spec | 検証対象 |
|---|---|
| `tests/unit/analyze_pdf.Tests.ps1` | `pdfimages -list` パース（suffix付き/byteのみ、mask/smask除外、画像ゼロ、DPI欠損） |
| `tests/unit/select_strategy.Tests.ps1` | 各 imageRatio 帯と DPI 帯で期待 strategy が選ばれる |
| `tests/unit/path-guard.Tests.ps1` | 境界外（UNC・長パス・相対・未作成・シンボリックリンク）拒否 |
| `tests/unit/enumerate_inputs.Tests.ps1` | `*.compressed.pdf` と `output\` 配下除外 |
| `tests/unit/compress_result.Tests.ps1` | 出力サイズ ≥ 元なら破棄し no-effect |
| `tests/unit/output_transaction.Tests.ps1` | durable journal、正常置換、crash復元、全file-presence状態、journal/path tamper、曖昧状態fail-closed |
| `tests/unit/installer_storage.Tests.ps1` | capacity式、非破壊retention候補列挙、明示承認された一世代cleanupのpath・marker・reparse guard |
| `tests/unit/invoke_args.Tests.ps1` | 配列引数のみ、文字列補間なし、特殊文字混入耐性 |
| `LossyRaster.Tests.ps1` | 劣化ラスタ圧縮の DPI/品質検証、`pdfimage24` 引数、shell string execution 不使用 |
| `tests/unit/dpi_validation.Tests.ps1` | DPI ホワイトリスト外で terminate |
| `tests/unit/gui-settings.Tests.ps1` | settings.json ロード／セーブ、バージョン非互換、欠損フィールド補完、JSON 破損時 fallback |
| `tests/unit/compress_args.Tests.ps1` | `-OutputRoot` / `-StrategyOverride` / `-StatusJson` の構造的存在、LogPath 既定がツール配下に分離されていること、`##STATUS##` 出力箇所の存在 |
| `tests/unit/gui_encoding.Tests.ps1` | `_internal/gui.ps1` が UTF-8 BOM 付きで保存されていること、`.editorconfig` / `.gitattributes` の対象ルール存在 |
| `tests/unit/gui_eventbridge.Tests.ps1` | `Register-ObjectEvent -Action` 内で関数呼び出しがなく `Enqueue` のみであること、`Receive-OutputQueues` / `Clear-OutputEventBridge` の定義、`Invoke-Cancel` の WaitForExit→drain→aborted→cleanup 順序 |
| `tests/unit/pwsh_required.Tests.ps1` | `gui.bat` / `compress.bat` / `install.bat` で `PSEXE=powershell` フォールバックが除去され、`where pwsh` 不在時に `exit /b 2` する分岐、および `pause` 方針 (gui のみ pause) |
| `public_v1_safety.Tests.ps1` | 入力ガード、manifest nonce、署名/ラスタ安全、feature action、PDF/A/X再生成警告、構造比較、target、GUI Run gate |
| `validate_output_contract.Tests.ps1` | qpdf exit 0/2/3/異常、警告差分、未知JSON version、ページ/Box/Rotate差分、CropBox正規化、locale不変 |
| `diagnostic_messages.Tests.ps1` | CLI/GUI共通診断メッセージの同一データソース |
| `tests/e2e/pdf_compressor_e2e.Tests.ps1` | provenance付き実PDF、Poppler metadata、実圧縮、qpdf check、JSONL/StatusJson |

実行: `pwsh _internal\run-tests.ps1`（`tests\` 配下から `*.Tests.ps1` を収集）。
`-Suite E2E` / `-Suite All` は必須外部ツール不足でexit 2、`-AllowMissingExternalTools` はローカルskip向けに限定する。
`-CodeCoverage`は`data/coverage-targets.json`のTier C0を計測し、JaCoCo集計が90%未満ならtest自体がgreenでもexit 1とする。

## 戦略追加手順

1. `data/strategies.schema.json` の `strategy_id` enum に追加
2. `compress.ps1` の `-StrategyOverride` ValidateSet と dispatch 分岐に追加
3. `select_strategy.ps1` の自動判定に入れる場合は分岐を追加。劣化戦略は原則 `auto` から除外
4. `tests/unit/select_strategy.Tests.ps1` と `tests/unit/compress_args.Tests.ps1` にケース追加
5. GUI 選択肢、`gui-settings.ps1` の許可リスト、README.md / ARCHITECTURE.md を更新

## runtime別package candidate

- canonical packageはschema v1の`win-x64`を維持し、新規候補は`installer/candidates/<run-id>`だけへ生成する。candidate buildはcanonical payloadを変更しない。
- 新規単一runtime候補もschema v3を使い、`payloads.<runtime>.build`へruntime別provenanceを置く。複数runtime合成時と同じvalidator境界を使用する。
- package入口は`x64-only`、`arm64-only`、`dual-runtime`の明示profileから生成し、生成BATのSHA-256をbuild receiptへ拘束する。配布方針はx64／ARM64別packageで、dual-runtimeは検証用途に限定する。
- 対応ソースは`_internal`、`src`、`installer`、`licenses`の製品source、固定dependency source archive、build recipeを含む。自己参照・生成物混入を防ぐため`installer/candidates`、`installer/payload`、`installer/_work`、`installer/dependency-evidence`、`bin`、`obj`をsource inventoryから除外する。
- `Test-Payload.ps1 -ExtractTo <empty-dir> -RunDiagnostics`でarchive hash、全file hash、tree digest、runtime architecture、native PE closure、build IDを検証し、その展開先へ`PDF_COMPRESSOR_INSTALL_ROOT`を固定してstrict E2EとIntegrationを実行する。

## リリース前手動検証チェックリスト

1. テキスト主体 PDF → `qpdf-lossless` 選定、サイズ縮小または `[SKIP] no-effect`
2. 高 DPI スキャン PDF → `gs-downsample-150` 選定、品質許容内でサイズ削減
3. 混在 PDF → `gs-downsample-180` 選定
4. 画像なし PDF → `qpdf-lossless`、視覚差なし
5. 劣化圧縮明示指定 → `gs-raster-low-quality` / `gs-raster-readable`、ページ数・MediaBox/CropBox・向きが維持され、サイズが元より小さい
6. 暗号化 PDF → `[FAIL]` 出力、exit 1
7. `_internal\run-tests.ps1` 全 spec 緑

担当責任者は変更ごとに ARCHITECTURE.md の本セクションを更新する。

## 遅延リファクタタスク（着手トリガー付き）

> セルフレビュー（計画ファイル `plans/pdf-compressor-self-review-fixplan.md` は 2026-09-04 時点で workspace に存在せず、原文を参照できない）で検出されたが、ship 阻害ではないため遅延適用としているリファクタ群。
> **次に該当ファイルを改修する開発者は、機能追加の前に本セクションのタスクを先に解消すること。** 機能追加と同 PR にしない（レビュー範囲が膨らみ revert 困難になる）。

| ID | 内容 | 影響ファイル | 着手トリガー | 期限 |
|---|---|---|---|---|
| **P1-5 ✅ 2026-07-07** | GUI が `_internal/path-guard.ps1` を直接 dot-source していた。GUI 側は `Test-OutputPathLocalHint` による UX hint のみにし、境界判定の正本は `compress.ps1` 子プロセスの exit 5 解釈に一本化した | `_internal/gui.ps1`, `_internal/compress.ps1` | 完了 | 完了 |
| **P1-10 ✅ 2026-07-30** | `_internal/compress.ps1` の path 導出、ログ整形、work-directory 管理を `output-path.ps1` / `log-format.ps1` / `work-dir.ps1` へ分割。`tool-resolver.ps1` と合わせて orchestrator の責務を縮小した | `_internal/compress.ps1`, `_internal/output-path.ps1`, `_internal/log-format.ps1`, `_internal/work-dir.ps1` | 完了 | 完了 |
| **P1-14 ✅ 2026-07-30** | `Get-OutputPathFor` と script-scope の衝突状態を廃止し、`Resolve-OutputPath -SeenMap ([ref]$map)` へ移行。run 単位の衝突マップを呼び出し側から注入する構造にした | `_internal/output-path.ps1`, `_internal/compress.ps1` | 完了 | 完了 |

### 運用ルール

- 本テーブルは着手済 (`✅ done`) でも残す（履歴として参考になるため）。完了時は ID 横に `✅ <PR番号> <日付>` を追記。
- 新規の遅延リファクタを追加する時は、`着手トリガー`と`期限`の両方を必ず書く。
- 期限が来ても着手されない場合は、独立 PR として強制実施（自身が改修する）。

### 関連ドキュメント

- ワークスペース横断 TODO インデックス: [../../TODO.md](../../TODO.md)（workspace 内部。単独リポジトリとして公開する際は除去する）
- 一般公開 master plan: [../../plans/pdf-compressor-public-release-master-plan.md](../../plans/pdf-compressor-public-release-master-plan.md)
- 旧セルフレビュー計画 `plans/pdf-compressor-self-review-fixplan.md` は消失しており参照できない（2026-09-04 確認）。P1-5 / P1-10 / P1-14 の実施内容は上表と `TODO.md` の Completed 節を正本とする。
- PR1〜PR5 適用済差分: `git log --oneline _internal/`
