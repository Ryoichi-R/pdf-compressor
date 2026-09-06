# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    pdf-compressor WinForms GUI.

.DESCRIPTION
    Provides drag-and-drop file/folder selection, strategy override,
    force overwrite, output-root selection (local-drive only), progress bar,
    cancel button, and persistent user settings.

    Invokes _internal/compress.ps1 as a child process with -StatusJson and
    parses ##STATUS## lines from stdout to update the UI.

.NOTES
    Must be saved as UTF-8 with BOM (see .editorconfig / .gitattributes).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-GuiStartupTrace([string]$Checkpoint) {
    $tracePath = [Environment]::GetEnvironmentVariable('PDF_COMPRESSOR_STARTUP_TRACE')
    if ([string]::IsNullOrWhiteSpace($tracePath)) { return }
    try {
        $line = "{0:o}|pid={1}|{2}{3}" -f [DateTimeOffset]::Now, $PID, $Checkpoint, [Environment]::NewLine
        [IO.File]::AppendAllText($tracePath, $line, [Text.UTF8Encoding]::new($false))
    } catch {
        # Diagnostic-only: tracing must never block the GUI.
    }
}

Write-GuiStartupTrace 'script-entered'

# ----------------------------------------------------------------------------
# Bootstrapping
# ----------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:ScriptDir   = $PSScriptRoot
$script:ToolRoot    = Split-Path -Parent $script:ScriptDir
$script:CompressPs1 = Join-Path $script:ScriptDir 'compress.ps1'
$script:WorkRoot    = Join-Path $script:ToolRoot '_work'
$script:LogJsonl    = Join-Path (Join-Path $script:ToolRoot 'output') 'compress.log.jsonl'

. (Join-Path $script:ScriptDir 'jsonl-writer.ps1')
. (Join-Path $script:ScriptDir 'gui-settings.ps1')
. (Join-Path $script:ScriptDir 'gui-queue.ps1')
. (Join-Path $script:ScriptDir 'tool-resolver.ps1')
. (Join-Path $script:ScriptDir 'tool-capabilities.ps1')
. (Join-Path $script:ScriptDir 'diagnostic-messages.ps1')
$script:DiagnosticsPs1 = Join-Path $script:ScriptDir 'diagnostics.ps1'
$previousDiagnosticSkip = $env:PDFCOMP_SKIP_MAIN
try {
    # Import the CLI diagnostic functions without running its CLI entrypoint.
    $env:PDFCOMP_SKIP_MAIN = '1'
    . $script:DiagnosticsPs1
} finally {
    if ($null -eq $previousDiagnosticSkip) { Remove-Item Env:PDFCOMP_SKIP_MAIN -ErrorAction SilentlyContinue }
    else { $env:PDFCOMP_SKIP_MAIN = $previousDiagnosticSkip }
}

# ----------------------------------------------------------------------------
# pwsh resolution
# ----------------------------------------------------------------------------
function Resolve-PowerShellExe {
    if ($env:PDF_COMPRESSOR_INSTALL_ROOT -and $env:PDF_COMPRESSOR_PWSH) {
        $installRoot = [IO.Path]::GetFullPath($env:PDF_COMPRESSOR_INSTALL_ROOT).TrimEnd('\')
        $bundled = [IO.Path]::GetFullPath($env:PDF_COMPRESSOR_PWSH)
        if (-not $bundled.StartsWith(
                $installRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'gui: bundled PowerShell path is outside the install root.'
        }
        if (-not (Test-Path -LiteralPath $bundled -PathType Leaf)) {
            throw "gui: bundled PowerShell is missing: $bundled"
        }
        return $bundled
    }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh -and (Test-Path -LiteralPath $pwsh.Source)) {
        return $pwsh.Source
    }
    throw "gui: pwsh (PowerShell 7+) is required but was not found on PATH. Install via 'winget install --id Microsoft.PowerShell'."
}

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------
$script:Settings           = $null
$script:ChildProc          = $null
$script:CancelRequested    = $false
$script:LastInFlightFile   = $null
$script:ChildReportedAbort = $false
$script:OkCount            = 0
$script:SkipCount          = 0
$script:FailCount          = 0
$script:TotalCount         = 0
$script:TotalOriginalBytes = 0L
$script:TotalCompressedBytes = 0L
$script:RatioFileCount     = 0
$script:OutputValid        = $true
$script:StdoutQueue        = $null
$script:StderrQueue        = $null
$script:StdoutSubscription = $null
$script:StderrSubscription = $null
$script:SuppressLossyConfirm = $false
$script:Queue               = New-GuiQueueState
$script:QueuePaths          = [System.Collections.Generic.List[string]]::new()
$script:LastOutputPath      = $null
$script:CurrentManifestPath = $null
$script:CancelFilePath      = $null
$script:SafetyConfirmationPending = $false
$script:GuiCapabilities = $null
$script:RequiredCapabilitiesAvailable = $false
$script:DiagnosticMessages = $null
$script:DiagnosticMessagePath = Join-Path $script:ScriptDir 'data\diagnostic-messages.json'
try {
    $script:GuiCapabilities = Get-ToolCapabilities -CachePath (Join-Path $script:ScriptDir 'data\tool-paths.json')
    $script:RequiredCapabilitiesAvailable = [bool]$script:GuiCapabilities.safe_ready
} catch {
    $script:RequiredCapabilitiesAvailable = $false
}
try {
    if (Test-Path -LiteralPath $script:DiagnosticMessagePath -PathType Leaf) {
        $script:DiagnosticMessages = Get-Content -LiteralPath $script:DiagnosticMessagePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
} catch { $script:DiagnosticMessages = $null }
$script:StrategyLabelById = [ordered]@{
    'auto'                  = '自動（おすすめ）'
    'qpdf-lossless'         = '無劣化（テキスト/図面向け）'
    'gs-downsample-150'     = '強く圧縮（高DPIスキャン向け）'
    'gs-downsample-180'     = 'バランス（文字+画像）'
    'gs-light-regenerate'   = '軽く再生成（低/中DPIスキャン）'
    'gs-raster-low-quality' = '最大圧縮・画像化（検索不可）'
    'gs-raster-readable'    = '可読性優先・画像化（検索不可）'
}
$script:StrategyIdByLabel = @{}
foreach ($strategyId in $script:StrategyLabelById.Keys) {
    $script:StrategyIdByLabel[$script:StrategyLabelById[$strategyId]] = $strategyId
}

function Get-StrategyLabel {
    param([string]$StrategyId)
    if ($script:StrategyLabelById.Contains($StrategyId)) {
        return $script:StrategyLabelById[$StrategyId]
    }
    return $script:StrategyLabelById['auto']
}

function Get-SelectedStrategyId {
    param([object]$SelectedItem)
    $label = [string]$SelectedItem
    if (-not [string]::IsNullOrWhiteSpace($label) -and $script:StrategyIdByLabel.ContainsKey($label)) {
        return $script:StrategyIdByLabel[$label]
    }
    if ($script:StrategyLabelById.Contains($label)) {
        return $label
    }
    return 'auto'
}

# ----------------------------------------------------------------------------
# UI build
# ----------------------------------------------------------------------------
$script:Settings = Get-GuiSettings

$form              = New-Object System.Windows.Forms.Form
$form.Text         = 'pdf-compressor'
$form.Size         = New-Object System.Drawing.Size $script:Settings.windowSize.w, $script:Settings.windowSize.h
$form.MinimumSize  = New-Object System.Drawing.Size 700, 560
$form.StartPosition = 'Manual'
if ($script:Settings.windowPos.x -ge 0 -and $script:Settings.windowPos.y -ge 0) {
    $form.Location = New-Object System.Drawing.Point $script:Settings.windowPos.x, $script:Settings.windowPos.y
} else {
    $form.StartPosition = 'CenterScreen'
}
$form.AllowDrop = $true

$margin    = 12
$btnW      = 80
$btnH      = 26
$gap       = 8
$clientW   = $form.ClientSize.Width
$rightEdge = $clientW - $margin   # x coordinate of the right boundary for anchored controls
$y         = $margin

# --- Input row ---
$lblInput = New-Object System.Windows.Forms.Label
$lblInput.Text     = '入力ファイル / フォルダ (D&D 可)'
$lblInput.Location = New-Object System.Drawing.Point $margin, $y
$lblInput.AutoSize = $true
$form.Controls.Add($lblInput)
$y += 20

$btnOpenInput = New-Object System.Windows.Forms.Button
$btnOpenInput.Text     = 'フォルダ追加'
$btnOpenInput.Size     = New-Object System.Drawing.Size $btnW, $btnH
$btnOpenInput.Location = New-Object System.Drawing.Point ($rightEdge - $btnW), $y
$btnOpenInput.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnOpenInput)

$btnBrowseInput = New-Object System.Windows.Forms.Button
$btnBrowseInput.Text     = 'PDFを追加'
$btnBrowseInput.Size     = New-Object System.Drawing.Size $btnW, $btnH
$btnBrowseInput.Location = New-Object System.Drawing.Point ($rightEdge - $btnW - $gap - $btnW), $y
$btnBrowseInput.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnBrowseInput)

$btnRemoveInput = New-Object System.Windows.Forms.Button
$btnRemoveInput.Text     = '選択を削除'
$btnRemoveInput.Size     = New-Object System.Drawing.Size $btnW, $btnH
$btnRemoveInput.Location = New-Object System.Drawing.Point ($rightEdge - ($btnW * 3) - ($gap * 2)), $y
$btnRemoveInput.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$btnRemoveInput.Enabled  = $false
$form.Controls.Add($btnRemoveInput)

$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Location = New-Object System.Drawing.Point $margin, $y
$txtInput.Size     = New-Object System.Drawing.Size (($rightEdge - ($btnW * 3) - ($gap * 3)) - $margin), 24
$txtInput.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$txtInput.Text     = $script:Settings.lastInput
$txtInput.Visible  = $false
$form.Controls.Add($txtInput)

$dgvQueue = New-Object System.Windows.Forms.DataGridView
$dgvQueue.Location = New-Object System.Drawing.Point $margin, $y
$dgvQueue.Size = New-Object System.Drawing.Size (($rightEdge - $margin), 72)
$dgvQueue.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$dgvQueue.AllowUserToAddRows = $false
$dgvQueue.AllowUserToDeleteRows = $false
$dgvQueue.ReadOnly = $true
$dgvQueue.RowHeadersVisible = $false
$dgvQueue.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvQueue.MultiSelect = $true
[void]$dgvQueue.Columns.Add('state', '状態')
[void]$dgvQueue.Columns.Add('file', 'ファイル名')
[void]$dgvQueue.Columns.Add('size', '元サイズ')
[void]$dgvQueue.Columns.Add('mode', 'モード')
$dgvQueue.Columns.Add('safety', '安全') | Out-Null
$dgvQueue.Columns.Add('target', '目標') | Out-Null
$dgvQueue.Columns.Add('features', '機能') | Out-Null
$dgvQueue.Columns.Add('verification', '検証') | Out-Null
$dgvQueue.Columns.Add('reason', '理由') | Out-Null
$dgvQueue.Columns.Add('strategy', '戦略') | Out-Null
$dgvQueue.Columns.Add('ocr', 'OCR') | Out-Null
$dgvQueue.Columns.Add('output', '出力') | Out-Null
$dgvQueue.Columns.Add('tool', 'ツール') | Out-Null
$dgvQueue.Size = New-Object System.Drawing.Size (($rightEdge - $margin), 150)
$form.Controls.Add($dgvQueue)
$y += 162

# --- Strategy row ---
$lblStrategy = New-Object System.Windows.Forms.Label
$lblStrategy.Text     = '戦略'
$lblStrategy.Location = New-Object System.Drawing.Point $margin, ($y + 4)
$lblStrategy.AutoSize = $true
$form.Controls.Add($lblStrategy)

$cmbStrategy = New-Object System.Windows.Forms.ComboBox
$cmbStrategy.Location      = New-Object System.Drawing.Point ($margin + 60), $y
$strategyW                 = 390
$cmbStrategy.Size          = New-Object System.Drawing.Size $strategyW, 24
$cmbStrategy.DropDownStyle = 'DropDownList'
[void]$cmbStrategy.Items.AddRange([string[]]$script:StrategyLabelById.Values)
$idx = $cmbStrategy.Items.IndexOf((Get-StrategyLabel -StrategyId $script:Settings.lastStrategy))
if ($idx -lt 0) { $idx = 0 }
$cmbStrategy.SelectedIndex = $idx
$form.Controls.Add($cmbStrategy)

$chkForce = New-Object System.Windows.Forms.CheckBox
$chkForce.Text     = '既存出力を上書き (--Force)'
$chkForce.Location = New-Object System.Drawing.Point ($margin + 60 + $strategyW + 16), ($y + 2)
$chkForce.AutoSize = $true
$chkForce.Checked  = [bool]$script:Settings.force
$form.Controls.Add($chkForce)
$y += 34

# --- User-facing policy row. Raw strategy remains an advanced override. ---
$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text = 'モード'
$lblMode.Location = New-Object System.Drawing.Point $margin, ($y + 4)
$lblMode.AutoSize = $true
$form.Controls.Add($lblMode)

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.Location = New-Object System.Drawing.Point ($margin + 60), $y
$cmbMode.Size = New-Object System.Drawing.Size 230, 24
$cmbMode.DropDownStyle = 'DropDownList'
[void]$cmbMode.Items.AddRange([string[]]@('自動（おすすめ）','高画質・無劣化優先','標準（容量と可読性）','最小容量'))
$modeLabels = @('auto','high-quality','standard','minimum-size')
$modeIndex = [array]::IndexOf($modeLabels, [string]$script:Settings.mode)
if ($modeIndex -lt 0) { $modeIndex = 0 }
$cmbMode.SelectedIndex = $modeIndex
$form.Controls.Add($cmbMode)

$lblSafety = New-Object System.Windows.Forms.Label
$lblSafety.Text = '安全'
$lblSafety.Location = New-Object System.Drawing.Point ($margin + 310), ($y + 4)
$lblSafety.AutoSize = $true
$form.Controls.Add($lblSafety)
$cmbSafety = New-Object System.Windows.Forms.ComboBox
$cmbSafety.Location = New-Object System.Drawing.Point ($margin + 350), $y
$cmbSafety.Size = New-Object System.Drawing.Size 100, 24
$cmbSafety.DropDownStyle = 'DropDownList'
[void]$cmbSafety.Items.AddRange([string[]]@('Safe','Warn','Off'))
$safetyIndex = $cmbSafety.Items.IndexOf([string]$script:Settings.safetyMode)
if ($safetyIndex -lt 0) { $safetyIndex = 0 }
$cmbSafety.SelectedIndex = $safetyIndex
$form.Controls.Add($cmbSafety)

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = '目標bytes'
$lblTarget.Location = New-Object System.Drawing.Point ($margin + 470), ($y + 4)
$lblTarget.AutoSize = $true
$form.Controls.Add($lblTarget)
$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point ($margin + 540), $y
$txtTarget.Size = New-Object System.Drawing.Size 120, 24
$txtTarget.Text = if ($script:Settings.targetBytes) { [string]$script:Settings.targetBytes } else { '' }
$form.Controls.Add($txtTarget)
$chkConfirmSafety = New-Object System.Windows.Forms.CheckBox
$chkConfirmSafety.Text = '不確実な検出を許可（明示確認）'
$chkConfirmSafety.Location = New-Object System.Drawing.Point ($margin + 670), ($y + 2)
$chkConfirmSafety.AutoSize = $true
$chkConfirmSafety.Checked = $false
$form.Controls.Add($chkConfirmSafety)
$y += 34

# --- Output row ---
$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text     = '出力先フォルダ (未指定なら <toolroot>\output\)'
$lblOutput.Location = New-Object System.Drawing.Point $margin, $y
$lblOutput.AutoSize = $true
$form.Controls.Add($lblOutput)
$y += 20

$btnOpenOutput = New-Object System.Windows.Forms.Button
$btnOpenOutput.Text     = '開く'
$btnOpenOutput.Size     = New-Object System.Drawing.Size $btnW, $btnH
$btnOpenOutput.Location = New-Object System.Drawing.Point ($rightEdge - $btnW), $y
$btnOpenOutput.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnOpenOutput)

$btnBrowseOutput = New-Object System.Windows.Forms.Button
$btnBrowseOutput.Text     = '参照...'
$btnBrowseOutput.Size     = New-Object System.Drawing.Size $btnW, $btnH
$btnBrowseOutput.Location = New-Object System.Drawing.Point ($rightEdge - $btnW - $gap - $btnW), $y
$btnBrowseOutput.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnBrowseOutput)

$btnDiagnostics = New-Object System.Windows.Forms.Button
$btnDiagnostics.Text     = '診断'
$btnDiagnostics.Size     = New-Object System.Drawing.Size $btnW, $btnH
$btnDiagnostics.Location = New-Object System.Drawing.Point ($rightEdge - ($btnW * 3) - ($gap * 2)), $y
$btnDiagnostics.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnDiagnostics)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location = New-Object System.Drawing.Point $margin, $y
$txtOutput.Size     = New-Object System.Drawing.Size (($rightEdge - ($btnW * 3) - ($gap * 3)) - $margin), 24
$txtOutput.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$txtOutput.Text     = $script:Settings.outputRoot
$form.Controls.Add($txtOutput)
$y += 32

# --- Progress row ---
$progLblW = 110
$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text      = '0 / 0 files'
$lblProgress.Location  = New-Object System.Drawing.Point ($rightEdge - $progLblW), ($y + 3)
$lblProgress.Size      = New-Object System.Drawing.Size $progLblW, 20
$lblProgress.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblProgress.Anchor    = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($lblProgress)

$prgFiles = New-Object System.Windows.Forms.ProgressBar
$prgFiles.Location = New-Object System.Drawing.Point $margin, $y
$prgFiles.Size     = New-Object System.Drawing.Size (($rightEdge - $progLblW - $gap) - $margin), 22
$prgFiles.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$prgFiles.Minimum  = 0
$prgFiles.Maximum  = 1
$prgFiles.Value    = 0
$form.Controls.Add($prgFiles)
$y += 30

# --- Log ---
$summaryRowH = 38
$logH = $form.ClientSize.Height - $y - $margin - $summaryRowH - $gap
if ($logH -lt 80) { $logH = 80 }
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location   = New-Object System.Drawing.Point $margin, $y
$txtLog.Size       = New-Object System.Drawing.Size ($clientW - ($margin * 2)), $logH
$txtLog.Anchor     = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$txtLog.Multiline  = $true
$txtLog.ReadOnly   = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.WordWrap   = $false
$txtLog.Font       = New-Object System.Drawing.Font 'Consolas', 9
$form.Controls.Add($txtLog)
$y += $logH + $gap

# --- Summary + buttons ---
$runBtnW = 100
$openBtnW = 110
$runBtnH = 30
$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Text     = 'total=0 ok=0 skip=0 fail=0'
$lblSummary.Location = New-Object System.Drawing.Point $margin, ($y + 6)
$lblSummary.Size     = New-Object System.Drawing.Size (($rightEdge - ($openBtnW * 4) - ($runBtnW * 2) - ($gap * 6)) - $margin), 22
$lblSummary.AutoSize = $false
$lblSummary.AutoEllipsis = $true
$lblSummary.Anchor   = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($lblSummary)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text     = '中止'
$btnCancel.Size     = New-Object System.Drawing.Size $openBtnW, $runBtnH
$btnCancel.Location = New-Object System.Drawing.Point ($rightEdge - $openBtnW), $y
$btnCancel.Anchor   = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$btnCancel.Enabled  = $false
$form.Controls.Add($btnCancel)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text     = '実行'
$btnRun.Size     = New-Object System.Drawing.Size $openBtnW, $runBtnH
$btnRun.Location = New-Object System.Drawing.Point ($rightEdge - ($openBtnW * 2) - $gap), $y
$btnRun.Anchor   = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnRun)

$btnOpenResult = New-Object System.Windows.Forms.Button
$btnOpenResult.Text = '結果PDFを開く'
$btnOpenResult.Size = New-Object System.Drawing.Size $openBtnW, $runBtnH
$btnOpenResult.Location = New-Object System.Drawing.Point ($rightEdge - ($openBtnW * 4) - ($gap * 3)), $y
$btnOpenResult.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnOpenResult)

$btnRevealResult = New-Object System.Windows.Forms.Button
$btnRevealResult.Text = '結果PDFの場所'
$btnRevealResult.Size = New-Object System.Drawing.Size $openBtnW, $runBtnH
$btnRevealResult.Location = New-Object System.Drawing.Point ($rightEdge - ($openBtnW * 3) - ($gap * 2)), $y
$btnRevealResult.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnRevealResult)

$btnOpenSource = New-Object System.Windows.Forms.Button
$btnOpenSource.Text = '元PDFを開く'
$btnOpenSource.Size = New-Object System.Drawing.Size $openBtnW, $runBtnH
$btnOpenSource.Location = New-Object System.Drawing.Point ($rightEdge - ($openBtnW * 6) - ($gap * 5)), $y
$btnOpenSource.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnOpenSource)

$btnRevealSource = New-Object System.Windows.Forms.Button
$btnRevealSource.Text = '元PDFの場所'
$btnRevealSource.Size = New-Object System.Drawing.Size $openBtnW, $runBtnH
$btnRevealSource.Location = New-Object System.Drawing.Point ($rightEdge - ($openBtnW * 5) - ($gap * 4)), $y
$btnRevealSource.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($btnRevealSource)
Write-GuiStartupTrace 'controls-created'

$script:PreflightTimer = New-Object System.Windows.Forms.Timer
$script:PreflightTimer.Interval = 400
$script:PreflightPollTimer = New-Object System.Windows.Forms.Timer
$script:PreflightPollTimer.Interval = 50
$script:IsPreflightRunning = $false

# ----------------------------------------------------------------------------
# UI helpers
# ----------------------------------------------------------------------------
function Get-GuiModeId {
    $labels = @('auto','high-quality','standard','minimum-size')
    $index = $cmbMode.SelectedIndex
    if ($index -lt 0 -or $index -ge $labels.Count) { return 'auto' }
    return $labels[$index]
}

function Get-GuiTargetBytes {
    if ([string]::IsNullOrWhiteSpace($txtTarget.Text)) { return $null }
    $value = 0L
    if (-not [long]::TryParse($txtTarget.Text.Trim(), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    if ($value -le 0) { return $null }
    return $value
}

function Get-GuiPropertyValue {
    param([object]$Object,[Parameter(Mandatory)][string]$Name,[object]$Default = '')
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-GuiFeatureSummary {
    param([object]$Features)
    if ($null -eq $Features) { return '-' }
    $container = if ($Features -is [System.Collections.IDictionary] -and $Features.Contains('features')) { $Features['features'] }
                 elseif ($Features.PSObject.Properties['features']) { $Features.features }
                 else { $Features }
    $present = @()
    $properties = if ($container -is [System.Collections.IDictionary]) {
        @($container.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
    } else { @($container.PSObject.Properties) }
    foreach ($property in $properties) {
        $state = if ($property.Value -and $property.Value.PSObject.Properties['state']) { [string]$property.Value.state } else { [string]$property.Value }
        if ($state -eq 'present') { $present += [string]$property.Name }
    }
    if ($present.Count -eq 0) { return 'なし' }
    return ($present -join ',')
}

function Update-GuiQueueView {
    $dgvQueue.Rows.Clear()
    foreach ($item in $script:Queue.items) {
        $file = Get-Item -LiteralPath $item.input_path -ErrorAction SilentlyContinue
        $size = if ($file) { Format-UiSize -Bytes ([long]$file.Length) } else { '-' }
        $result = Get-GuiPropertyValue -Object $item -Name 'result' -Default $null
        $analysis = Get-GuiPropertyValue -Object $item -Name 'analysis' -Default $null
        $featureSource = Get-GuiPropertyValue -Object $result -Name 'features' -Default (Get-GuiPropertyValue -Object $analysis -Name 'features' -Default $null)
        $verificationText = Get-GuiPropertyValue -Object $result -Name 'verification_status' -Default (Get-GuiPropertyValue -Object $analysis -Name 'verification_status' -Default '-')
        $strategyText = Get-GuiPropertyValue -Object $result -Name 'strategy_id' -Default (Get-GuiPropertyValue -Object $analysis -Name 'strategy_id' -Default (Get-GuiPropertyValue -Object $item -Name 'strategy_id' -Default 'auto'))
        $target = Get-GuiPropertyValue -Object $item -Name 'target_bytes' -Default $null
        $targetText = if ($null -ne $target) { [string]$target } else { '-' }
        $reason = Get-GuiPropertyValue -Object $result -Name 'stop_reason' -Default ''
        if ([string]::IsNullOrWhiteSpace([string]$reason)) { $reason = Get-GuiPropertyValue -Object $result -Name 'fail_reason' -Default '' }
        $verificationReasons = @(Get-GuiPropertyValue -Object $result -Name 'verification_reasons' -Default @())
        if ([string]$reason -eq 'validation-rejected' -and $verificationReasons.Count -gt 0) {
            $reason = ($verificationReasons -join ',')
        }
        if ([string]::IsNullOrWhiteSpace([string]$reason)) { $reason = Get-GuiPropertyValue -Object $item -Name 'policy_reason' -Default '' }
        if ([string]::IsNullOrWhiteSpace([string]$reason)) { $reason = Get-GuiPropertyValue -Object $analysis -Name 'reason' -Default '-' }
        $outputText = Get-GuiPropertyValue -Object $result -Name 'output_path' -Default '-'
        if ($outputText -and [string]$outputText -ne '-') { $outputText = Split-Path -Leaf ([string]$outputText) }
        $row = $dgvQueue.Rows.Add(
            [string]$item.state,
            (Split-Path -Leaf $item.input_path),
            $size,
            [string]$item.mode,
            [string]$item.safety_mode,
            $targetText,
            (Get-GuiFeatureSummary -Features $featureSource),
            $verificationText,
            [string]$reason,
            (Get-StrategyLabel -StrategyId ([string]$strategyText)),
            (Get-GuiPropertyValue -Object $result -Name 'ocr_status' -Default '-'),
            [string]$outputText,
            (Get-GuiPropertyValue -Object $result -Name 'tool' -Default '-'))
        $dgvQueue.Rows[$row].Tag = $item.item_id
    }
    $progress = Get-GuiQueueProgress -Queue $script:Queue
    $lblProgress.Text = "$($progress.done) / $($progress.total) files"
    Update-RemoveInputGate
}

function Update-RemoveInputGate {
    $btnRemoveInput.Enabled = (-not [bool]$script:ChildProc -and $dgvQueue.SelectedRows.Count -gt 0)
}

function Sync-GuiQueuePaths {
    $script:QueuePaths.Clear()
    foreach ($item in $script:Queue.items) { $script:QueuePaths.Add([string]$item.input_path) }
    $txtInput.Text = ($script:QueuePaths -join ';')
}

function Remove-GuiSelectedQueueItems {
    if ($script:ChildProc) {
        Write-LogUI '[INFO] 診断または圧縮の実行中はキューから削除できません。'
        Update-RemoveInputGate
        return
    }
    $itemIds = @($dgvQueue.SelectedRows | ForEach-Object { [string]$_.Tag } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($itemIds.Count -eq 0) { return }
    $removed = Remove-GuiQueueItems -Queue $script:Queue -ItemIds $itemIds
    if ($removed.removed_count -le 0) { return }
    Sync-GuiQueuePaths
    Update-GuiQueueView
    Update-SafetyConfirmationGate
    Update-RunGate | Out-Null
    if (@($script:Queue.items | Where-Object { $_.state -eq 'analyzing' }).Count -eq 0) { $script:PreflightTimer.Stop() }
    Write-LogUI ("[QUEUE] {0} file(s) removed" -f $removed.removed_count)
}

function Update-SafetyConfirmationGate {
    $uncertain = @($script:Queue.items | Where-Object {
        $a = Get-GuiPropertyValue -Object $_ -Name 'analysis' -Default $null
        $v = Get-GuiPropertyValue -Object $a -Name 'verification_status' -Default 'not-run'
        $v -in @('indeterminate','unavailable','warning')
    }).Count -gt 0
    $script:SafetyConfirmationPending = ($uncertain -and -not [bool]$chkConfirmSafety.Checked)
}

function Add-GuiInputPaths {
    param([Parameter(Mandatory)][string[]]$Paths)
    foreach ($rawPath in $Paths) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) { continue }
        $path = $rawPath.Trim('"')
        if (-not (Test-Path -LiteralPath $path)) { Write-LogUI "[WARN] 入力が存在しません: $path"; continue }
        $item = Get-Item -LiteralPath $path -Force
        $files = if ($item.PSIsContainer) {
            @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter '*.pdf' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.compressed.pdf' })
        } else {
            if ($item.Extension -ine '.pdf') { Write-LogUI "[WARN] PDF以外を無視しました: $path"; @() } else { @($item) }
        }
        foreach ($file in $files) {
            $alreadyQueued = @($script:QueuePaths | Where-Object {
                ([string]$_).Equals($file.FullName, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
            if ($alreadyQueued) { continue }
            $script:QueuePaths.Add($file.FullName)
            $queueItem = New-GuiQueueItem -InputPath $file.FullName -Mode (Get-GuiModeId) -SafetyMode ([string]$cmbSafety.SelectedItem) -TargetBytes (Get-GuiTargetBytes)
            [void](Add-GuiQueueItem -Queue $script:Queue -Item $queueItem)
            [void](Set-GuiQueueItemState -Item $queueItem -State 'analyzing')
        }
    }
    $txtInput.Text = ($script:QueuePaths -join ';')
    Update-GuiQueueView
    $script:PreflightTimer.Stop()
    if (-not $script:ChildProc) { $script:PreflightTimer.Start() }
    Update-SafetyConfirmationGate
    Update-RunGate
}

function Update-RunGate {
    $availability = Update-RunAvailability -Queue $script:Queue -Button $btnRun -OutputValid:$script:OutputValid -RequiredCapabilitiesAvailable:$script:RequiredCapabilitiesAvailable -SafetyConfirmationPending:$script:SafetyConfirmationPending -ChildProcessRunning:([bool]$script:ChildProc)
    if (-not $availability.enabled -and $availability.reasons.Count -gt 0) { $btnRun.AccessibleDescription = ($availability.reasons -join ', ') }
    return $availability
}

function Write-LogUI {
    param([string]$Line)
    if ($null -eq $Line) { return }
    $action = {
        param($text)
        $txtLog.AppendText($text + [Environment]::NewLine)
    }
    if ($txtLog.InvokeRequired) {
        [void]$txtLog.BeginInvoke($action, @($Line))
    } else {
        & $action $Line
    }
}

function Set-UIEnabled {
    param([bool]$Enabled)
    $controls = @($txtInput, $dgvQueue, $btnBrowseInput, $btnOpenInput, $cmbStrategy, $cmbMode, $cmbSafety, $txtTarget, $chkForce,
                  $chkConfirmSafety, $txtOutput, $btnBrowseOutput, $btnOpenOutput, $btnDiagnostics, $btnOpenSource, $btnRevealSource,
                  $btnOpenResult, $btnRevealResult, $btnRun)
    foreach ($c in $controls) { $c.Enabled = $Enabled }
    $btnRemoveInput.Enabled = $false
    $btnCancel.Enabled = -not $Enabled
    if ($Enabled) {
        $btnCancel.Text = '中止'
        Update-RemoveInputGate
        Update-RunGate
    }
}

function Show-GuiDiagnosticsDialog {
    $outputRoot = if ([string]::IsNullOrWhiteSpace($txtOutput.Text)) { Join-Path $script:ToolRoot 'output' } else { $txtOutput.Text }
    try {
        $script:GuiCapabilities = Get-ToolCapabilities -CachePath (Join-Path $script:ScriptDir 'data\tool-paths.json')
        $script:RequiredCapabilitiesAvailable = [bool]$script:GuiCapabilities.safe_ready
        $report = Get-PdfCompressorDiagnostics -ToolRoot $script:ToolRoot -Capabilities $script:GuiCapabilities -OutputRoot $outputRoot -WorkRoot $script:WorkRoot -LogPath (Join-Path $outputRoot 'compress.log.jsonl')
        Update-RunGate
    } catch {
        $report = [pscustomobject]@{ error = $_.Exception.Message; safe_ready = $false; missing_required = @(); tools = @(); write_checks = @(); telemetry = 'none'; pdf_content_external = $false }
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '環境診断'
    $dialog.Size = New-Object System.Drawing.Size 760, 560
    $dialog.MinimumSize = New-Object System.Drawing.Size 620, 420
    $dialog.StartPosition = 'CenterParent'
    $dialog.ShowInTaskbar = $false

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point 12, 12
    $status.Size = New-Object System.Drawing.Size 710, 24
    $status.Text = if ($report.safe_ready) { 'Safe実行: 利用可能' } else { 'Safe実行: 利用不可（不足・書込み状態を確認してください）' }
    $status.ForeColor = if ($report.safe_ready) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
    $dialog.Controls.Add($status)

    $details = New-Object System.Windows.Forms.TextBox
    $details.Location = New-Object System.Drawing.Point 12, 42
    $details.Size = New-Object System.Drawing.Size 720, 430
    $details.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = 'Both'
    $details.WordWrap = $false
    $details.Font = New-Object System.Drawing.Font 'Consolas', 9
    $details.Text = ($report | ConvertTo-Json -Depth 12)
    $dialog.Controls.Add($details)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = '閉じる'
    $close.Size = New-Object System.Drawing.Size 90, 28
    $close.Location = New-Object System.Drawing.Point 642, 480
    $close.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
    $close.Add_Click({ $dialog.Close() })
    $dialog.Controls.Add($close)
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

function Test-OutputPathLocalHint {
    param([string]$TargetPath)
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $true }
    if ($TargetPath.StartsWith('\\?\') -or $TargetPath.StartsWith('\\.\') -or $TargetPath.StartsWith('\\')) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($TargetPath)) { return $false }
    $pathRoot = [System.IO.Path]::GetPathRoot($TargetPath)
    if ($pathRoot -notmatch '^[A-Za-z]:\\$') { return $false }
    return (Test-Path -LiteralPath $pathRoot)
}

function Update-OutputValidationStyle {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $txtOutput.BackColor = [System.Drawing.SystemColors]::Window
        $script:OutputValid = $true
        if (Get-Command Update-RunGate -ErrorAction SilentlyContinue) { Update-RunGate }
        return
    }
    if (Test-OutputPathLocalHint -TargetPath $Path) {
        $txtOutput.BackColor = [System.Drawing.SystemColors]::Window
        $script:OutputValid = $true
    } else {
        $txtOutput.BackColor = [System.Drawing.Color]::MistyRose
        $script:OutputValid = $false
    }
    if (Get-Command Update-RunGate -ErrorAction SilentlyContinue) { Update-RunGate }
}

function Reset-RunState {
    $script:OkCount = 0
    $script:SkipCount = 0
    $script:FailCount = 0
    $script:TotalCount = 0
    $script:TotalOriginalBytes = 0L
    $script:TotalCompressedBytes = 0L
    $script:RatioFileCount = 0
    $script:LastInFlightFile = $null
    $script:ChildReportedAbort = $false
    $prgFiles.Value = 0
    $prgFiles.Maximum = 1
    $lblProgress.Text = '0 / 0 files'
    $lblSummary.Text = 'total=0 ok=0 skip=0 fail=0'
}

function Format-UiSize {
    param([long]$Bytes)
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $idx = 0
    while ($value -ge 1024 -and $idx -lt ($units.Count - 1)) {
        $value = $value / 1024
        $idx++
    }
    if ($idx -eq 0) {
        return ("{0} {1}" -f [long]$value, $units[$idx])
    }
    return ("{0:0.0} {1}" -f $value, $units[$idx])
}

function Get-CompressionSummaryText {
    $done = $script:OkCount + $script:SkipCount + $script:FailCount
    $base = "total=$done ok=$($script:OkCount) skip=$($script:SkipCount) fail=$($script:FailCount)"
    if ($script:RatioFileCount -le 0 -or $script:TotalOriginalBytes -le 0) {
        return "$base saved=-"
    }

    $savedBytes = $script:TotalOriginalBytes - $script:TotalCompressedBytes
    $savedPct = [int][math]::Round($savedBytes * 100.0 / $script:TotalOriginalBytes)
    $orig = Format-UiSize -Bytes $script:TotalOriginalBytes
    $comp = Format-UiSize -Bytes $script:TotalCompressedBytes
    return ("{0} saved={1}% ({2} -> {3})" -f $base, $savedPct, $orig, $comp)
}

# ----------------------------------------------------------------------------
# Status line handling (called on UI thread via BeginInvoke)
# ----------------------------------------------------------------------------
function Invoke-StatusLine {
    param([string]$JsonBody)
    try {
        $obj = $JsonBody | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-LogUI "[WARN] cannot parse status line: $JsonBody"
        return
    }
    if (-not $obj.PSObject.Properties['event']) { return }
    switch ($obj.event) {
        'start' {
            $total = if ($obj.PSObject.Properties['total']) { [int]$obj.total } else { 0 }
            $script:TotalCount = $total
            $prgFiles.Maximum = [Math]::Max(1, $total)
            $prgFiles.Value = 0
            $lblProgress.Text = "0 / $total files"
        }
        'queue' {
            $total = if ($obj.PSObject.Properties['total']) { [int]$obj.total } else { 0 }
            $script:TotalCount = $total
            $prgFiles.Maximum = [Math]::Max(1, $total)
            $lblProgress.Text = "0 / $total files"
        }
        'analysis' {
            $file = if ($obj.PSObject.Properties['file']) { [string]$obj.file } else { '' }
            $reason = if ($obj.PSObject.Properties['reason']) { [string]$obj.reason } else { '' }
            if ($file) {
                $queueItem = @($script:Queue.items | Where-Object { ([string]$_.input_path).Equals($file, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                if ($queueItem) {
                    if ($queueItem.PSObject.Properties['analysis']) { $queueItem.analysis = $obj } else { Add-Member -InputObject $queueItem -NotePropertyName analysis -NotePropertyValue $obj }
                    if ($queueItem.state -eq 'analyzing') { [void](Set-GuiQueueItemState -Item $queueItem -State 'ready') }
                }
                Update-SafetyConfirmationGate
                Write-LogUI ("[診断] {0} {1} ({2})" -f (Split-Path -Leaf $file), (Get-DiagnosticMessage -Code $reason -Data $script:DiagnosticMessages), $reason)
                Update-GuiQueueView
            }
        }
        'diagnostic' {
            if ($obj.PSObject.Properties['missing_required'] -and @($obj.missing_required).Count -gt 0) {
                $script:RequiredCapabilitiesAvailable = $false
                $missing = @($obj.missing_required)
                $details = @($missing | ForEach-Object { Get-DiagnosticMessage -Code ("{0}-unavailable" -f $_) -Data $script:DiagnosticMessages }) -join '; '
                Write-LogUI ("[診断] 必須ツール不足: {0} ({1})" -f ($missing -join ', '), $details)
                Update-RunGate
            }
        }
        'verification' {
            if ($obj.PSObject.Properties['status']) {
                # Wrap the whole conditional so an empty reasons collection remains
                # an empty array under StrictMode instead of collapsing to $null.
                $reasonCodes = @(
                    if ($obj.PSObject.Properties['reasons']) {
                        $obj.reasons | ForEach-Object { [string]$_ }
                    }
                )
                if ($reasonCodes.Count -gt 0) {
                    $messages = @($reasonCodes | ForEach-Object { Get-DiagnosticMessage -Code $_ -Data $script:DiagnosticMessages })
                    Write-LogUI ("[検証] {0}: {1} ({2})" -f $obj.status, ($messages -join '; '), ($reasonCodes -join ', '))
                } else {
                    Write-LogUI ("[検証] {0}" -f $obj.status)
                }
            }
        }
        'file-start' {
            $file = if ($obj.PSObject.Properties['file']) { [string]$obj.file } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($file)) {
                $script:LastInFlightFile = $file
            }
        }
        'aborted' {
            $file = if ($obj.PSObject.Properties['file']) { [string]$obj.file } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($file)) {
                $script:LastInFlightFile = $file
            }
        }
        'file' {
            $script:LastInFlightFile = if ($obj.PSObject.Properties['file']) { [string]$obj.file } else { $null }
            if ($obj.PSObject.Properties['output_path']) { $script:LastOutputPath = [string]$obj.output_path }
            $status = if ($obj.PSObject.Properties['status']) { [string]$obj.status } else { 'fail' }
            $failReason = if ($obj.PSObject.Properties['fail_reason']) { [string]$obj.fail_reason } else { '' }
            $stopReason = if ($obj.PSObject.Properties['stop_reason']) { [string]$obj.stop_reason } else { '' }
            $isAborted = $status -eq 'fail' -and ($failReason -eq 'aborted' -or $stopReason -eq 'aborted')
            if ($isAborted) { $script:ChildReportedAbort = $true }
            if ($script:LastInFlightFile) {
                $queueItem = @($script:Queue.items | Where-Object {
                    ([string]$_.input_path).Equals($script:LastInFlightFile, [System.StringComparison]::OrdinalIgnoreCase)
                }) | Select-Object -First 1
                if ($queueItem) {
                    try {
                        if ($queueItem.PSObject.Properties['result']) { $queueItem.result = $obj } else { Add-Member -InputObject $queueItem -NotePropertyName result -NotePropertyValue $obj }
                        if ($obj.PSObject.Properties['policy_reason']) {
                            if ($queueItem.PSObject.Properties['policy_reason']) { $queueItem.policy_reason = [string]$obj.policy_reason }
                            else { Add-Member -InputObject $queueItem -NotePropertyName policy_reason -NotePropertyValue ([string]$obj.policy_reason) }
                        }
                        if ($queueItem.state -eq 'ready') { [void](Set-GuiQueueItemState -Item $queueItem -State 'running') }
                        if ($queueItem.state -in @('pending','analyzing')) { [void](Set-GuiQueueItemState -Item $queueItem -State 'ready'); [void](Set-GuiQueueItemState -Item $queueItem -State 'running') }
                        $terminalState = if ($isAborted) {
                            'cancelled'
                        } else {
                            switch ($status) {
                                'ok' { 'ok' }
                                'skip' { 'skip' }
                                default { 'fail' }
                            }
                        }
                        if ($queueItem.state -eq 'running') { [void](Set-GuiQueueItemState -Item $queueItem -State $terminalState) }
                    } catch {
                        Write-LogUI ("[WARN] キュー状態を更新できません: {0}" -f $_.Exception.Message)
                    }
                    Update-GuiQueueView
                }
            }
            if ($obj.PSObject.Properties['stop_reason'] -and -not [string]::IsNullOrWhiteSpace([string]$obj.stop_reason)) {
                Write-LogUI ("[ACTION] {0}: {1}" -f (Split-Path -Leaf $script:LastInFlightFile), [string]$obj.stop_reason)
            }
            switch ($status) {
                'ok'   {
                    $script:OkCount++
                    if ($obj.PSObject.Properties['original'] -and $obj.PSObject.Properties['compressed']) {
                        $originalBytes = [long]$obj.original
                        $compressedBytes = [long]$obj.compressed
                        if ($originalBytes -gt 0 -and $compressedBytes -gt 0) {
                            $script:TotalOriginalBytes += $originalBytes
                            $script:TotalCompressedBytes += $compressedBytes
                            $script:RatioFileCount++
                        }
                    }
                }
                'skip' { $script:SkipCount++ }
                'fail' { if (-not $isAborted) { $script:FailCount++ } }
            }
            if ($prgFiles.Value -lt $prgFiles.Maximum) { $prgFiles.Value++ }
            $done = $script:OkCount + $script:SkipCount + $script:FailCount
            $lblProgress.Text = "$done / $($script:TotalCount) files"
            $lblSummary.Text = Get-CompressionSummaryText
        }
        'summary' {
            $tot = if ($obj.PSObject.Properties['total']) { [int]$obj.total } else { 0 }
            $okN = if ($obj.PSObject.Properties['ok'])    { [int]$obj.ok }    else { 0 }
            $skN = if ($obj.PSObject.Properties['skip'])  { [int]$obj.skip }  else { 0 }
            $fl  = if ($obj.PSObject.Properties['fail'])  { [int]$obj.fail }  else { 0 }
            $sr  = if ($obj.PSObject.Properties['skip_ratio']) { [int]$obj.skip_ratio } else { 0 }
            $ratioText = Get-CompressionSummaryText
            $lblSummary.Text = ("{0} skip_ratio={1}%" -f $ratioText, $sr)
            if ($obj.PSObject.Properties['stop_reasons'] -and @($obj.stop_reasons).Count -gt 0) {
                $reasonText = @($obj.stop_reasons | ForEach-Object { "{0}={1}" -f $_.reason, $_.count }) -join ', '
                Write-LogUI ("[ACTION] {0}" -f $reasonText)
            }
        }
        default { }
    }
}

function Receive-StdoutLine {
    param([string]$Line)
    if ($null -eq $Line) { return }
    if ($Line.StartsWith('##STATUS## ')) {
        $body = $Line.Substring(11)
        $action = { param($b) Invoke-StatusLine -JsonBody $b }
        if ($form.InvokeRequired) {
            [void]$form.BeginInvoke($action, @($body))
        } else {
            & $action $body
        }
    } else {
        Write-LogUI $Line
    }
}

# ----------------------------------------------------------------------------
# Child process management
# ----------------------------------------------------------------------------
function Receive-OutputQueues {
    $line = $null
    while ($script:StdoutQueue -and $script:StdoutQueue.TryDequeue([ref]$line)) {
        Receive-StdoutLine -Line $line
    }
    while ($script:StderrQueue -and $script:StderrQueue.TryDequeue([ref]$line)) {
        Receive-StdoutLine -Line ("[stderr] " + $line)
    }
}

function Clear-OutputEventBridge {
    foreach ($sub in @($script:StdoutSubscription, $script:StderrSubscription)) {
        if ($sub) {
            try { Unregister-Event -SourceIdentifier $sub.Name -ErrorAction SilentlyContinue } catch {}
            try { Remove-Job -Id $sub.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    $script:StdoutSubscription = $null
    $script:StderrSubscription = $null
    $script:StdoutQueue = $null
    $script:StderrQueue = $null
}

function Start-CompressJob {
    param(
        [Parameter(Mandatory)][string]$InputArg,
        [string]$OutputArg,
        [Parameter(Mandatory)][string]$StrategyArg,
        [bool]$ForceArg,
        [string]$ModeArg = 'auto',
        [string]$SafetyModeArg = 'Safe',
        [Nullable[long]]$TargetBytesArg,
        [switch]$EnableOcrArg,
        [string[]]$OcrLanguagesArg = @(),
        [switch]$AllowFullPageRasterArg,
        [switch]$UseManifestArg,
        [string]$RiskConsentNonceArg,
        [switch]$AllowReducedVerificationArg,
        [switch]$PreflightOnlyArg,
        [string]$CancelFileArg
    )
    $pwshPath = Resolve-PowerShellExe

    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add('-NoProfile')
    $argList.Add('-NonInteractive')
    $argList.Add('-ExecutionPolicy'); $argList.Add('Bypass')
    $argList.Add('-File'); $argList.Add($script:CompressPs1)
    if ($UseManifestArg) { $argList.Add('-InputManifest') } else { $argList.Add('-InputPath') }
    $argList.Add($InputArg)
    if (-not [string]::IsNullOrWhiteSpace($StrategyArg) -and $StrategyArg -ne 'auto') {
        $argList.Add('-StrategyOverride'); $argList.Add($StrategyArg)
    }
    $argList.Add('-Mode'); $argList.Add($ModeArg)
    $argList.Add('-SafetyMode'); $argList.Add($SafetyModeArg)
    $argList.Add('-StatusJson')
    if (-not [string]::IsNullOrWhiteSpace($CancelFileArg)) { $argList.Add('-CancelFile'); $argList.Add($CancelFileArg) }
    if ($PreflightOnlyArg) { $argList.Add('-PreflightOnly') }
    if ($AllowReducedVerificationArg) { $argList.Add('-AllowReducedVerification') }
    if ($ForceArg) { $argList.Add('-Force') }
    if (-not [string]::IsNullOrWhiteSpace($OutputArg)) {
        $argList.Add('-OutputRoot'); $argList.Add($OutputArg)
    }
    if ($null -ne $TargetBytesArg) { $argList.Add('-TargetBytes'); $argList.Add([string][long]$TargetBytesArg) }
    if ($EnableOcrArg) {
        $argList.Add('-EnableOcr')
        if ($OcrLanguagesArg.Count -gt 0) { $argList.Add('-OcrLanguages'); foreach ($language in $OcrLanguagesArg) { $argList.Add($language) } }
    }
    if ($AllowFullPageRasterArg) {
        $argList.Add('-AllowFullPageRaster')
        if ($UseManifestArg) {
            $argList.Add('-AcceptManifestRiskConsents')
            if (-not [string]::IsNullOrWhiteSpace($RiskConsentNonceArg)) { $argList.Add('-RiskConsentNonce'); $argList.Add($RiskConsentNonceArg) }
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $pwshPath
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow         = $true
    $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true

    $script:StdoutQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $script:StderrQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    try {
        $script:StdoutSubscription = Register-ObjectEvent -InputObject $proc `
            -EventName OutputDataReceived `
            -MessageData $script:StdoutQueue `
            -SourceIdentifier ("pdfcomp_stdout_" + [Guid]::NewGuid().ToString('N')) `
            -Action {
                $line = $EventArgs.Data
                if ($null -ne $line) { $Event.MessageData.Enqueue([string]$line) }
            }

        $script:StderrSubscription = Register-ObjectEvent -InputObject $proc `
            -EventName ErrorDataReceived `
            -MessageData $script:StderrQueue `
            -SourceIdentifier ("pdfcomp_stderr_" + [Guid]::NewGuid().ToString('N')) `
            -Action {
                $line = $EventArgs.Data
                if ($null -ne $line) { $Event.MessageData.Enqueue([string]$line) }
            }

        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
    } catch {
        Clear-OutputEventBridge
        throw
    }
    return $proc
}

function Clear-GuiCurrentManifest {
    if (-not $script:CurrentManifestPath -or -not (Test-Path -LiteralPath $script:CurrentManifestPath)) {
        $script:CurrentManifestPath = $null
        return
    }
    $manifestDir = Split-Path -Parent $script:CurrentManifestPath
    $workRootFull = [System.IO.Path]::GetFullPath($script:WorkRoot).TrimEnd('\')
    $manifestDirFull = [System.IO.Path]::GetFullPath($manifestDir).TrimEnd('\')
    if ($manifestDirFull.StartsWith($workRootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        try { Remove-Item -LiteralPath $manifestDirFull -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:CurrentManifestPath = $null
}

function Start-GuiPreflightBatch {
    if ($script:ChildProc) { return }
    $pending = @($script:Queue.items | Where-Object { $_.state -eq 'analyzing' })
    if ($pending.Count -eq 0) { Update-RunGate; return }
    $paths = @($pending | ForEach-Object { [string]$_.input_path })
    $strategy = Get-SelectedStrategyId -SelectedItem $cmbStrategy.SelectedItem
    if ([string]::IsNullOrWhiteSpace($strategy)) { $strategy = 'auto' }
    $modeId = Get-GuiModeId
    $safetyId = [string]$cmbSafety.SelectedItem
    if ([string]::IsNullOrWhiteSpace($safetyId)) { $safetyId = 'Safe' }
    $targetBytes = Get-GuiTargetBytes
    $allowRaster = $strategy -in @('gs-raster-low-quality','gs-raster-readable')
    $manifestInfo = $null
    try {
        $useManifest = $paths.Count -gt 1
        $inputArg = if ($useManifest) {
            $manifestInfo = New-GuiManifestFile -Paths $paths -ModeId $modeId -SafetyId $safetyId -Target $targetBytes -AllowRaster:$allowRaster
            $script:CurrentManifestPath = [string]$manifestInfo.path
            $manifestInfo.path
        } else { $paths[0] }
        $script:IsPreflightRunning = $true
        $riskNonce = if ($manifestInfo) { [string]$manifestInfo.nonce } else { '' }
        $script:ChildProc = Start-CompressJob -InputArg $inputArg -OutputArg '' -StrategyArg $strategy -ForceArg $false -ModeArg $modeId -SafetyModeArg $safetyId -TargetBytesArg $targetBytes -AllowFullPageRasterArg:$allowRaster -UseManifestArg:$useManifest -RiskConsentNonceArg $riskNonce -AllowReducedVerificationArg:$chkConfirmSafety.Checked -PreflightOnlyArg
        Write-LogUI ("[PREFLIGHT] {0} file(s) queued for one batch analysis" -f $paths.Count)
        $script:PreflightPollTimer.Start()
        Update-RemoveInputGate
        Update-RunGate
    } catch {
        Write-LogUI ("[ERROR] preflight failed to start: {0}" -f $_.Exception.Message)
        foreach ($item in $pending) {
            try { [void](Set-GuiQueueItemState -Item $item -State 'fail') } catch {}
        }
        Clear-GuiCurrentManifest
        $script:IsPreflightRunning = $false
        $script:ChildProc = $null
        Update-GuiQueueView
        Update-RemoveInputGate
        Update-RunGate
    }
}

$script:PreflightTimer.Add_Tick({
    $script:PreflightTimer.Stop()
    if (-not $script:ChildProc) { Start-GuiPreflightBatch }
})

$script:PreflightPollTimer.Add_Tick({
    if (-not $script:ChildProc) {
        $script:PreflightPollTimer.Stop()
        return
    }
    Receive-OutputQueues
    if (-not $script:ChildProc.HasExited) { return }
    [void]$script:ChildProc.WaitForExit()
    Receive-OutputQueues
    Start-Sleep -Milliseconds 50
    Receive-OutputQueues
    $exit = $script:ChildProc.ExitCode
    Clear-OutputEventBridge
    Clear-GuiCurrentManifest
    $script:ChildProc = $null
    $script:IsPreflightRunning = $false
    if ($exit -ne 0) {
        Write-LogUI ("[PREFLIGHT] child exit={0}" -f $exit)
        foreach ($item in @($script:Queue.items | Where-Object { $_.state -eq 'analyzing' })) {
            try { [void](Set-GuiQueueItemState -Item $item -State 'fail') } catch {}
        }
    } else {
        foreach ($item in @($script:Queue.items | Where-Object { $_.state -eq 'analyzing' })) {
            try { [void](Set-GuiQueueItemState -Item $item -State 'ready') } catch {}
        }
    }
    Update-GuiQueueView
    Update-RemoveInputGate
    Update-RunGate
    if (@($script:Queue.items | Where-Object { $_.state -eq 'analyzing' }).Count -gt 0) { $script:PreflightTimer.Start() }
})

function Write-AbortedJsonl {
    param([string]$InFlightFile)

    # Single append path shared with compress.ps1. The mutex inside
    # Write-JsonlRecord prevents race with any in-flight child write — there is
    # no need for the previous "flush polling" workaround, which never worked
    # against taskkill /F (a killed child cannot flush after death).
    $rec = [ordered]@{
        ts          = (Get-Date).ToUniversalTime().ToString('o')
        status      = 'fail'
        fail_reason = 'aborted'
        tool        = 'gui'
        file        = $InFlightFile
    }
    Write-JsonlRecord -Path $script:LogJsonl -Record $rec
}

function Clear-WorkSubdirs {
    param([int]$ChildPid)
    if (-not (Test-Path -LiteralPath $script:WorkRoot)) { return }
    $prefix = "$ChildPid-"
    Get-ChildItem -LiteralPath $script:WorkRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) } |
        ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
}

function Invoke-Cancel {
    if ($script:CancelRequested) { return }
    $script:CancelRequested = $true
    $btnCancel.Text = '中止中...'
    $btnCancel.Enabled = $false

    if ($script:ChildProc -and -not $script:ChildProc.HasExited) {
        $childPid = $script:ChildProc.Id
        $forcedFallback = $false
        try {
            if ($script:CancelFilePath) {
                [IO.File]::WriteAllText($script:CancelFilePath, ([DateTimeOffset]::Now.ToString('o') + "`n"), [Text.UTF8Encoding]::new($false))
                Write-LogUI '[CANCEL] cooperative stop requested; waiting up to 5 seconds'
            }
        } catch {
            Write-LogUI "[WARN] cancel marker failed: $($_.Exception.Message)"
        }
        $deadline = [DateTimeOffset]::Now.AddSeconds(5)
        while (-not $script:ChildProc.HasExited -and [DateTimeOffset]::Now -lt $deadline) {
            Receive-OutputQueues
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        if (-not $script:ChildProc.HasExited) {
            $forcedFallback = $true
            Write-LogUI '[CANCEL] grace period expired; forcing the owned process tree to stop'
            try { $script:ChildProc.Kill($true) } catch { Write-LogUI "[WARN] Process.Kill(tree) failed: $($_.Exception.Message)" }
        }
        if (-not $script:ChildProc.WaitForExit(3000)) {
            $forcedFallback = $true
            try {
                Start-Process -FilePath 'taskkill' -ArgumentList @('/T','/F','/PID', "$childPid") -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
            } catch { Write-LogUI "[WARN] final taskkill fallback failed: $($_.Exception.Message)" }
        }
        [void]$script:ChildProc.WaitForExit()
        Receive-OutputQueues
        Clear-WorkSubdirs -ChildPid $childPid
        Write-LogUI ("[CANCEL] forced_fallback={0}" -f $forcedFallback)
    }

    try {
        $cancelled = Complete-GuiQueueCancellation -Queue $script:Queue -InFlightPath $script:LastInFlightFile
        $script:LastInFlightFile = $cancelled.in_flight_path
        Update-GuiQueueView
        $lblSummary.Text = "cancelled=$($cancelled.cancelled_count)"
        if (-not $script:ChildReportedAbort) {
            Write-AbortedJsonl -InFlightFile $cancelled.in_flight_path
        }
    } catch {
        Write-LogUI "[P2] failed to append aborted record: $($_.Exception.Message)"
    }

    Write-LogUI '[ABORTED] processing stopped by user'
}

function Confirm-LossyRasterRun {
    param([Parameter(Mandatory)][string]$Strategy)
    $lossyRasterStrategies = @('gs-raster-low-quality', 'gs-raster-readable')
    if ($Strategy -notin $lossyRasterStrategies) { return $true }
    if ($script:SuppressLossyConfirm) { return $true }

    $message = "この戦略はページ全体を画像に変換します。`r`nテキスト検索、コピー、リンク、フォーム、しおり等は失われる可能性があります。`r`n続行しますか?"
    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'pdf-compressor',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function New-GuiManifestFile {
    param([Parameter(Mandatory)][string[]]$Paths,[Parameter(Mandatory)][string]$ModeId,[Parameter(Mandatory)][string]$SafetyId,[Nullable[long]]$Target,[switch]$AllowRaster)
    if (-not (Test-Path -LiteralPath $script:WorkRoot)) { New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null }
    $runDir = Join-Path $script:WorkRoot ("gui-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $manifestPath = Join-Path $runDir 'input.manifest.json'
    $nonce = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N'))
    $items = foreach ($path in $Paths) {
        [ordered]@{
            input_path = [System.IO.Path]::GetFullPath($path)
            mode = $null
            safety_mode = $null
            target_bytes = $null
            ocr = $null
            output_root = $null
            allow_signed_pdf = $false
            allow_full_page_raster = [bool]$AllowRaster
        }
    }
    $manifest = [ordered]@{
        version = '1.0'
        defaults = [ordered]@{
            mode = $ModeId
            safety_mode = $SafetyId
            target_bytes = if ($null -ne $Target) { [long]$Target } else { $null }
            ocr = [ordered]@{ enabled = $false; languages = @() }
        }
        items = @($items)
    }
    $manifest.risk_consent = [ordered]@{ nonce = $nonce; work_dir = $runDir }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    return [pscustomobject]@{ path = $manifestPath; nonce = $nonce; work_dir = $runDir }
}

function Get-GuiSelectedQueueItem {
    if ($dgvQueue.SelectedRows.Count -gt 0) {
        $index = [int]$dgvQueue.SelectedRows[0].Index
        if ($index -ge 0 -and $index -lt $script:Queue.items.Count) { return $script:Queue.items[$index] }
    }
    return $null
}

function Open-GuiPath {
    param([string]$Path,[string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-LogUI ("[INFO] {0} がまだ存在しません。対象を選択し、処理完了後に再試行してください。" -f $Label)
        return
    }
    try { Invoke-Item -LiteralPath $Path } catch { Write-LogUI ("[WARN] {0}を開けませんでした: {1}" -f $Label, $_.Exception.Message) }
}

function Show-GuiPathInExplorer {
    param([string]$Path,[string]$Label,[switch]$SelectFile)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-LogUI ("[INFO] {0} がまだ存在しません。対象を選択し、処理完了後に再試行してください。" -f $Label)
        return
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'explorer.exe'
        $psi.UseShellExecute = $true
        if ($SelectFile -and -not $item.PSIsContainer) {
            $psi.ArgumentList.Add('/select,')
            $psi.ArgumentList.Add($item.FullName)
        } else {
            $target = if ($item.PSIsContainer) { $item.FullName } else { $item.Directory.FullName }
            $psi.ArgumentList.Add($target)
        }
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-LogUI ("[WARN] {0}をエクスプローラーで表示できませんでした: {1}" -f $Label, $_.Exception.Message)
    }
}

# ----------------------------------------------------------------------------
# Event wiring
# ----------------------------------------------------------------------------
$form.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
})
$form.Add_DragDrop({
    param($sender, $e)
    $items = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    if ($items.Count -gt 0) { Add-GuiInputPaths -Paths $items }
})

$btnBrowseInput.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'PDF files (*.pdf)|*.pdf|All files (*.*)|*.*'
    $ofd.Multiselect = $true
    $ofd.CheckFileExists = $true
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Add-GuiInputPaths -Paths $ofd.FileNames }
})

$btnOpenInput.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Add-GuiInputPaths -Paths @($fbd.SelectedPath) }
})

$btnRemoveInput.Add_Click({ Remove-GuiSelectedQueueItems })
$dgvQueue.Add_SelectionChanged({ Update-RemoveInputGate })
$dgvQueue.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        Remove-GuiSelectedQueueItems
        $e.SuppressKeyPress = $true
        $e.Handled = $true
    }
})

$btnBrowseOutput.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    if (-not [string]::IsNullOrWhiteSpace($txtOutput.Text)) { $fbd.SelectedPath = $txtOutput.Text }
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtOutput.Text = $fbd.SelectedPath
        Update-OutputValidationStyle -Path $txtOutput.Text
        if (-not $script:OutputValid) {
            Write-LogUI "[WARN] 出力先がローカルドライブではありません: $($txtOutput.Text)"
        }
    }
})

$btnDiagnostics.Add_Click({ Show-GuiDiagnosticsDialog })

$btnOpenOutput.Add_Click({
    $p = if ([string]::IsNullOrWhiteSpace($txtOutput.Text)) {
        Join-Path $script:ToolRoot 'output'
    } else {
        $txtOutput.Text
    }
    if ((Test-OutputPathLocalHint -TargetPath $p) -and (Test-Path -LiteralPath $p)) {
        Show-GuiPathInExplorer -Path $p -Label '出力先フォルダ'
    }
})

$btnOpenSource.Add_Click({
    $item = Get-GuiSelectedQueueItem
    $path = if ($item) { [string]$item.input_path } else { [string]$script:LastInFlightFile }
    Open-GuiPath -Path $path -Label '元PDF'
})

$btnRevealSource.Add_Click({
    $item = Get-GuiSelectedQueueItem
    $path = if ($item) { [string]$item.input_path } else { [string]$script:LastInFlightFile }
    Show-GuiPathInExplorer -Path $path -Label '元PDF' -SelectFile
})

$btnOpenResult.Add_Click({
    $item = Get-GuiSelectedQueueItem
    $result = if ($item) { Get-GuiPropertyValue -Object $item -Name 'result' -Default $null } else { $null }
    $path = if ($result) { [string](Get-GuiPropertyValue -Object $result -Name 'output_path' -Default '') } else { [string]$script:LastOutputPath }
    Open-GuiPath -Path $path -Label '結果PDF'
})

$btnRevealResult.Add_Click({
    $item = Get-GuiSelectedQueueItem
    $result = if ($item) { Get-GuiPropertyValue -Object $item -Name 'result' -Default $null } else { $null }
    $path = if ($result) { [string](Get-GuiPropertyValue -Object $result -Name 'output_path' -Default '') } else { [string]$script:LastOutputPath }
    Show-GuiPathInExplorer -Path $path -Label '結果PDF' -SelectFile
})

$txtOutput.Add_TextChanged({
    Update-OutputValidationStyle -Path $txtOutput.Text
})

$chkConfirmSafety.Add_CheckedChanged({
    Update-SafetyConfirmationGate
    Update-RunGate
})

$btnRun.Add_Click({
    Update-SafetyConfirmationGate
    if ($script:SafetyConfirmationPending) {
        [System.Windows.Forms.MessageBox]::Show('圧縮前診断が完了していないか、検出結果が不確実です。確認チェックを入れてから実行してください。', 'pdf-compressor', 'OK', 'Warning') | Out-Null
        return
    }
    $readyItems = @($script:Queue.items | Where-Object { $_.state -in @('ready','cancelled') })
    if ($readyItems.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($txtInput.Text)) {
        Add-GuiInputPaths -Paths ($txtInput.Text -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $readyItems = @($script:Queue.items | Where-Object { $_.state -in @('ready','cancelled') })
    }
    if ($readyItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('入力ファイル/フォルダを指定してください。', 'pdf-compressor', 'OK', 'Warning') | Out-Null
        return
    }
    $outPath = $txtOutput.Text
    if (-not [string]::IsNullOrWhiteSpace($outPath) -and -not (Test-OutputPathLocalHint -TargetPath $outPath)) {
        Write-LogUI "[WARN] 出力先がローカルドライブではない可能性があります。最終判定は子プロセスで行います: $outPath"
    }
    $strategy = Get-SelectedStrategyId -SelectedItem $cmbStrategy.SelectedItem
    if ([string]::IsNullOrWhiteSpace($strategy)) { $strategy = 'auto' }
    $modeId = Get-GuiModeId
    $safetyId = [string]$cmbSafety.SelectedItem
    if ([string]::IsNullOrWhiteSpace($safetyId)) { $safetyId = 'Safe' }
    $targetBytes = Get-GuiTargetBytes
    if (-not [string]::IsNullOrWhiteSpace($txtTarget.Text) -and $null -eq $targetBytes) {
        [System.Windows.Forms.MessageBox]::Show('目標bytesは正の整数で指定してください。', 'pdf-compressor', 'OK', 'Warning') | Out-Null
        return
    }
    $allowRaster = $strategy -in @('gs-raster-low-quality','gs-raster-readable')
    if (-not (Confirm-LossyRasterRun -Strategy $strategy)) {
        Write-LogUI '[CANCELLED] lossy raster strategy confirmation declined'
        return
    }

    Reset-RunState
    foreach ($item in $readyItems) {
        if ($item.state -eq 'cancelled') { [void](Set-GuiQueueItemState -Item $item -State 'ready') }
        [void](Set-GuiQueueItemState -Item $item -State 'running')
    }
    Update-GuiQueueView
    Set-UIEnabled $false
    $readyPaths = @($readyItems | ForEach-Object { [string]$_.input_path })
    $script:LastInFlightFile = if ($readyPaths.Count -gt 0) { $readyPaths[0] } else { $null }
    $useManifest = $readyPaths.Count -gt 1
    $manifestInfo = $null
    $inputArg = if ($useManifest) {
        $manifestInfo = New-GuiManifestFile -Paths $readyPaths -ModeId $modeId -SafetyId $safetyId -Target $targetBytes -AllowRaster:$allowRaster
        $script:CurrentManifestPath = [string]$manifestInfo.path
        $manifestInfo.path
    } else {
        $readyPaths[0]
    }
    $riskNonce = if ($manifestInfo) { [string]$manifestInfo.nonce } else { '' }
    Write-LogUI ("[RUN] input_count={0} mode={1} safety={2} strategy={3} target={4} force={5} output='{6}'" -f $readyPaths.Count, $modeId, $safetyId, $strategy, $targetBytes, [bool]$chkForce.Checked, $outPath)

    try {
        try {
            $script:CancelRequested = $false
            if (-not (Test-Path -LiteralPath $script:WorkRoot)) { [IO.Directory]::CreateDirectory($script:WorkRoot) | Out-Null }
            $script:CancelFilePath = Join-Path $script:WorkRoot ("cancel-{0}-{1}.request" -f $PID, [Guid]::NewGuid().ToString('N'))
            $script:ChildProc = Start-CompressJob -InputArg $inputArg -OutputArg $outPath -StrategyArg $strategy -ForceArg ([bool]$chkForce.Checked) -ModeArg $modeId -SafetyModeArg $safetyId -TargetBytesArg $targetBytes -AllowFullPageRasterArg:$allowRaster -UseManifestArg:$useManifest -RiskConsentNonceArg $riskNonce -AllowReducedVerificationArg:$chkConfirmSafety.Checked -CancelFileArg $script:CancelFilePath
        } catch {
            Write-LogUI ("[ERROR] " + $_.Exception.Message)
            return
        }

        # Drive the message loop until the child exits, draining queued lines each tick.
        while ($script:ChildProc -and -not $script:ChildProc.HasExited) {
            Receive-OutputQueues
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }

        # Flush trailing stdout/stderr (BeginOutputReadLine can emit after HasExited).
        if ($script:ChildProc) {
            [void]$script:ChildProc.WaitForExit()
            Receive-OutputQueues
            Start-Sleep -Milliseconds 100
            Receive-OutputQueues
            $exit = $script:ChildProc.ExitCode
            if (-not $script:CancelRequested) {
                Write-LogUI "[DONE] child exit=$exit"
            }
        }

        if ($script:CancelRequested) {
            Receive-OutputQueues
        }
    } catch {
        Write-LogUI ("[ERROR] " + $_.Exception.Message)
    } finally {
        Clear-OutputEventBridge
        if ($script:CurrentManifestPath -and (Test-Path -LiteralPath $script:CurrentManifestPath)) {
            $manifestDir = Split-Path -Parent $script:CurrentManifestPath
            $workRootFull = [System.IO.Path]::GetFullPath($script:WorkRoot).TrimEnd('\')
            $manifestDirFull = [System.IO.Path]::GetFullPath($manifestDir).TrimEnd('\')
            if ($manifestDirFull.StartsWith($workRootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                try { Remove-Item -LiteralPath $manifestDirFull -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        $script:CurrentManifestPath = $null
        if ($script:CancelFilePath -and (Test-Path -LiteralPath $script:CancelFilePath)) { Remove-Item -LiteralPath $script:CancelFilePath -Force -ErrorAction SilentlyContinue }
        $script:CancelFilePath = $null
        $script:ChildProc = $null
        $script:CancelRequested = $false
        Set-UIEnabled $true
    }
})

$btnCancel.Add_Click({ Invoke-Cancel })
Write-GuiStartupTrace 'primary-events-wired'

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:ChildProc -and -not $script:ChildProc.HasExited) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            '処理中です。中止して終了しますか?',
            'pdf-compressor',
            'YesNo',
            'Question')
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            return
        }
        Invoke-Cancel
    }

    try {
        $script:Settings.lastInput    = $txtInput.Text
        $script:Settings.outputRoot   = $txtOutput.Text
        $script:Settings.lastStrategy = Get-SelectedStrategyId -SelectedItem $cmbStrategy.SelectedItem
        $script:Settings.force        = [bool]$chkForce.Checked
        $script:Settings.mode         = Get-GuiModeId
        $script:Settings.safetyMode   = [string]$cmbSafety.SelectedItem
        $script:Settings.targetBytes  = Get-GuiTargetBytes
        $script:Settings.windowSize.w = [int]$form.Width
        $script:Settings.windowSize.h = [int]$form.Height
        $script:Settings.windowPos.x  = [int]$form.Location.X
        $script:Settings.windowPos.y  = [int]$form.Location.Y
        Save-GuiSettings -Settings $script:Settings
    } catch {
        # Settings save failure is non-fatal.
    }
})

# Show and paint the form before any restored-state validation. Capability,
# output-path, queue, or previous-input work can involve filesystem/tool access;
# none of it may delay the first visible window. BeginInvoke runs after the
# first visible paint/message-loop turn.
$form.Add_Shown({
    Write-GuiStartupTrace 'form-shown-event'
    [void]$form.BeginInvoke([Action]{
        try {
            if (-not $script:RequiredCapabilitiesAvailable) {
                $missingAtStartup = if ($script:GuiCapabilities) { @($script:GuiCapabilities.missing_required) } else { @('qpdf','pdfinfo','pdfimages') }
                $startupDetails = @($missingAtStartup | ForEach-Object { Get-DiagnosticMessage -Code ("{0}-unavailable" -f $_) -Data $script:DiagnosticMessages }) -join '; '
                Write-LogUI ("[診断] Safe実行ゲートを無効化しました: {0}. {1}" -f ($missingAtStartup -join ', '), $startupDetails)
            }
            Update-OutputValidationStyle -Path $txtOutput.Text
            if (-not [string]::IsNullOrWhiteSpace($txtOutput.Text) -and -not $script:OutputValid) {
                Write-LogUI "[WARN] 復元した出力先がローカルドライブではないため未設定状態にしました。"
                $txtOutput.Text = ''
                Update-OutputValidationStyle -Path ''
            }
            Update-GuiQueueView
            Update-RunGate | Out-Null
            if (-not [string]::IsNullOrWhiteSpace($script:Settings.lastInput)) {
                Add-GuiInputPaths -Paths ($script:Settings.lastInput -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
        } catch {
            Write-LogUI ("[WARN] 起動時状態を復元できませんでした: " + $_.Exception.Message)
        }
    })
})

Write-GuiStartupTrace 'before-show-dialog'
[void]$form.ShowDialog()
Write-GuiStartupTrace 'after-show-dialog'
