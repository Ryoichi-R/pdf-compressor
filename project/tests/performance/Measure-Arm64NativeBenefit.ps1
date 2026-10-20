[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [Parameter(Mandatory)][string]$CorpusPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$InstallRoot = $env:PDF_COMPRESSOR_INSTALL_ROOT,
    [ValidateSet('auto', 'qpdf-lossless', 'gs-downsample-120', 'gs-downsample-150', 'gs-downsample-180', 'gs-light-regenerate', 'gs-raster-low-quality', 'gs-raster-readable')]
    [string]$Strategy = 'auto',
    [ValidateRange(0, 100)][int]$WarmupCount = 1,
    [ValidateRange(1, 100)][int]$TrialCount = 5,
    [string]$ThresholdPath
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# _internal/ARCHITECTURE.md exit code contract: 0 = every file handled,
# 6 = operator action required (safety SKIP, target miss). Both mean the
# pipeline ran to completion, so both are measurable. 1-5 are real errors.
$script:MeasurableExitCodes = @(0, 6)

function Get-CanonicalCorpusDigest([System.IO.FileInfo[]]$Files) {
    $lines = @($Files | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName
        '{0}|{1}|{2}' -f $relative, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToUpperInvariant(), $_.Length
    })
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '') } finally { $sha.Dispose() }
}

function Get-ProcessArgument([string]$Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-CompressionTrial([string]$Pwsh, [string]$CompressScript, [string]$InputRoot, [string]$OutputRoot, [string]$TrialLog, [string]$InstallRoot) {
    [IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Pwsh
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Arguments = @(
        '-NoProfile', '-File', (Get-ProcessArgument $CompressScript),
        '-InputPath', (Get-ProcessArgument $InputRoot),
        '-OutputRoot', (Get-ProcessArgument $OutputRoot),
        '-StrategyOverride', $Strategy,
        '-Force', '-StatusJson'
    ) -join ' '
    # The bundled tool resolver is hermetic only when this variable is set;
    # without it the child silently falls back to host PATH installations.
    $start.Environment['PDF_COMPRESSOR_INSTALL_ROOT'] = $InstallRoot
    $process = [Diagnostics.Process]::Start($start)
    # Drain both pipes while the child runs. Waiting for exit before reading
    # deadlocks as soon as the child writes more than the pipe buffer holds.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $peak = [long]0
    $wall = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        try { if ($process.WorkingSet64 -gt $peak) { $peak = $process.WorkingSet64 } } catch {}
        Start-Sleep -Milliseconds 50
    }
    try { if ($process.WorkingSet64 -gt $peak) { $peak = $process.WorkingSet64 } } catch {}
    $process.WaitForExit()
    $wall.Stop()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($TrialLog, ($stdout + "`n" + $stderr), [Text.UTF8Encoding]::new($false))
    $outputFiles = @(Get-ChildItem -LiteralPath $OutputRoot -Recurse -File -Filter '*.pdf' -ErrorAction SilentlyContinue)
    $outputBytes = [long](($outputFiles | Measure-Object -Property Length -Sum).Sum)
    return [pscustomobject]@{
        exitCode = $process.ExitCode
        wallTimeMs = [long]$wall.ElapsedMilliseconds
        peakWorkingSetBytes = $peak
        inputBytes = [long]((Get-ChildItem -LiteralPath $InputRoot -Recurse -File -Filter '*.pdf' | Measure-Object -Property Length -Sum).Sum)
        outputBytes = $outputBytes
        outputFileCount = $outputFiles.Count
        error = if ($script:MeasurableExitCodes -contains $process.ExitCode) { $null } else { 'compression-process-failed' }
    }
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw 'InstallRoot is required. Set PDF_COMPRESSOR_INSTALL_ROOT or pass -InstallRoot.' }
$installRootFull = [IO.Path]::GetFullPath($InstallRoot)
$corpusFull = [IO.Path]::GetFullPath($CorpusPath)
if (-not (Test-Path -LiteralPath $corpusFull -PathType Container)) { throw "Corpus directory is missing: $corpusFull" }
$files = @(Get-ChildItem -LiteralPath $corpusFull -Recurse -File -Filter '*.pdf' | Sort-Object FullName)
if ($files.Count -lt 1) { throw 'Corpus must contain at least one PDF.' }
$pwsh = Join-Path $installRootFull 'runtime\pwsh\pwsh.exe'
$compressScript = Join-Path $installRootFull '_internal\compress.ps1'
if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw "Bundled PowerShell is missing: $pwsh" }
if (-not (Test-Path -LiteralPath $compressScript -PathType Leaf)) { throw "Compression script is missing: $compressScript" }
$outputFull = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory((Split-Path -Parent $outputFull)) | Out-Null
$corpusDigest = Get-CanonicalCorpusDigest $files
$receipt = [ordered]@{
    schemaVersion = 1
    status = 'not-evaluated'
    runtime = $Runtime
    host = [ordered]@{ osArchitecture = [string]$env:PROCESSOR_ARCHITEW6432; processorArchitecture = [string]$env:PROCESSOR_ARCHITECTURE }
    corpus = [ordered]@{ path = $corpusFull; fileCount = $files.Count; sha256 = $corpusDigest }
    warmupCount = $WarmupCount
    trialCount = $TrialCount
    strategy = $Strategy
    trials = @()
    thresholdEvaluation = [ordered]@{ status = 'not-evaluated'; reason = 'Owner-approved threshold was not supplied.' }
    createdAt = [DateTimeOffset]::Now.ToString('o')
}

$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdf-compressor-arm64-benefit-' + [Guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    for ($index = 0; $index -lt ($WarmupCount + $TrialCount); $index++) {
        $trialRoot = Join-Path $runRoot ("trial-{0:D2}" -f $index)
        $trial = Invoke-CompressionTrial $pwsh $compressScript $corpusFull $trialRoot (Join-Path $runRoot ("trial-{0:D2}.log" -f $index)) $installRootFull
        if ($index -ge $WarmupCount) { $receipt.trials += $trial }
    }
    $failedTrials = @($receipt.trials | Where-Object { $null -ne $_.error })
    if ($failedTrials.Count -gt 0) {
        $receipt.status = 'failed'
        $receipt.error = 'One or more measured trials failed.'
    } else {
        $receipt.status = 'measured'
    }
    if (-not [string]::IsNullOrWhiteSpace($ThresholdPath)) {
        $threshold = Get-Content -LiteralPath ([IO.Path]::GetFullPath($ThresholdPath)) -Raw | ConvertFrom-Json
        if ($threshold.schemaVersion -ne 1 -or $threshold.status -ne 'approved') { throw 'Threshold file is not an approved schema v1 threshold.' }
        $receipt.thresholdEvaluation = [ordered]@{ status = 'not-evaluated'; thresholdId = [string]$threshold.thresholdId; reason = 'Metric-specific threshold evaluation must be approved with the corpus and runtime pair.' }
    }
} finally {
    if (Test-Path -LiteralPath $runRoot) { Remove-Item -LiteralPath $runRoot -Recurse -Force }
}

[IO.File]::WriteAllText($outputFull, (($receipt | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
$receipt
