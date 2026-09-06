[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateRoot,
    [ValidateRange(10, 300)][int]$TimeoutSeconds = 120,
    [string]$ReceiptPath,
    [switch]$CleanupExtracted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..\..')).TrimEnd('\')
$candidate = [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\')
if (-not $candidate.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'CandidateRoot must be inside the PDF Compressor project root.'
}
$manifestPath = Join-Path $candidate 'payload-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Candidate payload manifest is missing.'
}
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $ReceiptPath = Join-Path $workspaceRoot "result\pdf-compressor\performance-target-size-worst-case-$stamp.json"
}
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if (-not $ReceiptPath.StartsWith($workspaceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReceiptPath must be inside the workspace root.'
}

. (Join-Path $projectRoot 'tests\support\New-SyntheticPdf.ps1')

function Get-DirectoryByteCount {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0L }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return 0L }
    $measure = $files | Measure-Object Length -Sum
    return [long]$measure.Sum
}

$runId = [Guid]::NewGuid().ToString('N')
$workParent = [IO.Path]::GetFullPath((Join-Path $projectRoot 'installer\_work')).TrimEnd('\')
$extractRoot = [IO.Path]::GetFullPath((Join-Path $workParent "target-size-performance-$runId"))
if (-not $extractRoot.StartsWith($workParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Performance extraction path escaped the owned work root.'
}
[IO.Directory]::CreateDirectory($extractRoot) | Out-Null
$ownerMarker = Join-Path $workParent ".pdf-compressor-target-performance-$runId.owned"
[IO.File]::WriteAllText($ownerMarker, $runId, [Text.UTF8Encoding]::new($false))

try {
    & (Join-Path $projectRoot 'installer\Test-Payload.ps1') -ManifestPath $manifestPath -Runtime 'win-x64' -ExtractTo $extractRoot | Out-Null

    $inputRoot = Join-Path $extractRoot 'benchmark-input'
    $outputRoot = Join-Path $extractRoot 'benchmark-output'
    [IO.Directory]::CreateDirectory($inputRoot) | Out-Null
    [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $inputPdf = Join-Path $inputRoot 'target-worst-case-10mib-50page.pdf'
    $requestedBytes = 10MB
    $rasterAsciiBytes = 2L * 1600L * 2000L + 1L
    $contentTargetBytes = [math]::Max(0L, $requestedBytes - $rasterAsciiBytes)
    New-SyntheticPdf -OutputPath $inputPdf -PageCount 50 -TargetBytes $contentTargetBytes -IncludeRasterImage -RasterWidth 1600 -RasterHeight 2000 | Out-Null
    $inputBytes = [long](Get-Item -LiteralPath $inputPdf).Length
    $logPath = Join-Path $outputRoot 'target-run.jsonl'
    $stdoutPath = Join-Path $outputRoot 'target-run.stdout.txt'
    $stderrPath = Join-Path $outputRoot 'target-run.stderr.txt'

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $extractRoot 'runtime\pwsh\pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PDF_COMPRESSOR_INSTALL_ROOT'] = $extractRoot
    foreach ($argument in @(
            '-NoProfile', '-File', (Join-Path $extractRoot '_internal\compress.ps1'),
            '-InputPath', $inputPdf, '-OutputRoot', $outputRoot, '-LogPath', $logPath,
            '-Mode', 'auto', '-SafetyMode', 'Off', '-TargetBytes', '1', '-StatusJson'
        )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) { throw 'Failed to start the extracted target-size CLI.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $peakWorkingSet = 0L
    $peakOwnedWorkBytes = 0L
    $timedOut = $false
    while (-not $process.HasExited) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            $timedOut = $true
            $process.Kill($true)
            break
        }
        try {
            $process.Refresh()
            $peakWorkingSet = [math]::Max($peakWorkingSet, [long]$process.WorkingSet64)
        } catch { }
        $peakOwnedWorkBytes = [math]::Max($peakOwnedWorkBytes, (Get-DirectoryByteCount -Path (Join-Path $extractRoot '_work')))
        Start-Sleep -Milliseconds 100
    }
    $process.WaitForExit()
    $watch.Stop()
    $processExitCode = if ($timedOut) { $null } else { [int]$process.ExitCode }
    [IO.File]::WriteAllText($stdoutPath, $stdoutTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrPath, $stderrTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    $process.Dispose()

    $records = @()
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $records = @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    $fileRecord = @($records | Where-Object { $_.PSObject.Properties['item_id'] } | Select-Object -Last 1)
    $outputPdf = @(Get-ChildItem -LiteralPath $outputRoot -Filter '*.pdf' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    $outputBytes = if ($outputPdf.Count -gt 0) { [long]$outputPdf[0].Length } else { 0L }
    $qpdfExitCode = $null
    if ($outputPdf.Count -gt 0) {
        & (Join-Path $extractRoot 'runtime\tools\qpdf.exe') '--check' '--' $outputPdf[0].FullName *> $null
        $qpdfExitCode = [int]$LASTEXITCODE
    }
    $attemptCount = if ($fileRecord.Count -gt 0 -and $fileRecord[0].PSObject.Properties['attempt_count']) { [int]$fileRecord[0].attempt_count } else { 0 }
    $targetStatus = if ($fileRecord.Count -gt 0) { [string]$fileRecord[0].target_status } else { $null }
    $pass = -not $timedOut -and $processExitCode -eq 6 -and $attemptCount -ge 1 -and $attemptCount -le 7 -and
        $targetStatus -eq 'not-met' -and $outputBytes -gt 0 -and $qpdfExitCode -in @(0, 3) -and
        $watch.Elapsed.TotalSeconds -le $TimeoutSeconds -and $peakOwnedWorkBytes -le 512MB
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receipt = [ordered]@{
        schemaVersion = 1
        measuredAtUtc = [DateTime]::UtcNow.ToString('o')
        status = if ($pass) { 'pass' } else { 'fail' }
        benchmark = 'target-size-worst-case'
        candidate = [ordered]@{ root = $candidate; buildId = $manifest.buildId; sourceDigest = $manifest.sourceDigest; archiveSha256 = $manifest.payloads.'win-x64'.sha256 }
        fixture = [ordered]@{ requestedBytes = $requestedBytes; actualBytes = $inputBytes; pageCount = 50; rasterWidth = 1600; rasterHeight = 2000 }
        request = [ordered]@{ mode = 'auto'; safetyMode = 'Off'; targetBytes = 1 }
        limits = [ordered]@{ maxAttempts = 7; timeoutSeconds = $TimeoutSeconds; maxOwnedWorkBytes = 512MB }
        result = [ordered]@{
            exitCode = $processExitCode
            timedOut = $timedOut
            wallMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 3)
            attemptCount = $attemptCount
            targetStatus = $targetStatus
            stopReason = if ($fileRecord.Count -gt 0) { [string]$fileRecord[0].stop_reason } else { $null }
            outputBytes = $outputBytes
            qpdfCheckExitCode = $qpdfExitCode
            peakDirectWorkingSetBytes = $peakWorkingSet
            peakOwnedWorkBytes = $peakOwnedWorkBytes
        }
        limitations = @(
            'The current minimum-size policy can expose fewer than seven available candidates; the assertion is bounded to one through seven actual attempts.',
            'Direct bundled PowerShell working set is sampled every 100 ms. Child Ghostscript memory is covered by the separate ghostscript-strategy-resource-matrix receipt, whose measured maximum was 27652096 bytes.',
            'Peak owned work covers the extracted runtime _work directory and excludes the immutable installed payload and benchmark input.'
        )
    }
    $receiptDirectory = Split-Path -Parent $ReceiptPath
    if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) { [IO.Directory]::CreateDirectory($receiptDirectory) | Out-Null }
    [IO.File]::WriteAllText($ReceiptPath, (($receipt | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{
        receiptPath = $ReceiptPath
        status = $receipt.status
        attempts = $attemptCount
        wallMs = $receipt.result.wallMs
        retainedExtractRoot = if ($CleanupExtracted) { $null } else { $extractRoot }
    }
} catch {
    $errorText = "Target-size benchmark failed: {0}`n{1}`n{2}" -f $_.Exception.ToString(), $_.ScriptStackTrace, ($_ | Out-String)
    [IO.File]::WriteAllText((Join-Path $extractRoot 'benchmark-error.txt'), $errorText, [Text.UTF8Encoding]::new($false))
    Write-Error $errorText
    throw
} finally {
    if ($CleanupExtracted -and (Test-Path -LiteralPath $extractRoot -PathType Container)) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $extractRoot).Path)
        if (-not $resolved.StartsWith($workParent + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup path escaped the owned work root.' }
        if (-not (Test-Path -LiteralPath $ownerMarker -PathType Leaf)) { throw 'Performance cleanup owner marker is missing.' }
        $reparse = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($reparse.Count -gt 0) { throw 'Performance cleanup refused a reparse point.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Remove-Item -LiteralPath $ownerMarker -Force
    }
}
