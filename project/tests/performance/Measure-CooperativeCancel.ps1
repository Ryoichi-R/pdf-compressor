[CmdletBinding()]
param(
    [ValidateRange(3, 10)][int]$Runs = 3,
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..\..')).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $ReceiptPath = Join-Path $workspaceRoot "result\pdf-compressor\performance-cooperative-cancel-$stamp.json"
}
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if (-not $ReceiptPath.StartsWith($workspaceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'ReceiptPath must be inside the workspace root.' }

. (Join-Path $projectRoot 'tests\support\New-SyntheticPdf.ps1')
$runId = [Guid]::NewGuid().ToString('N')
$ownedParent = [IO.Path]::GetFullPath((Join-Path $projectRoot '_work')).TrimEnd('\')
$ownedRoot = [IO.Path]::GetFullPath((Join-Path $ownedParent "cancel-performance-$runId"))
if (-not $ownedRoot.StartsWith($ownedParent + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cancel benchmark path escaped the owned root.' }
New-Item -ItemType Directory -Path $ownedRoot -Force | Out-Null
$ownerMarker = Join-Path $ownedRoot '.pdf-compressor-performance-owned'
[IO.File]::WriteAllText($ownerMarker, $runId, [Text.UTF8Encoding]::new($false))

try {
    $requestedBytes = 10MB
    $rasterAsciiBytes = 2L * 1600L * 2000L + 1L
    $inputPdf = Join-Path $ownedRoot 'cancel-input.pdf'
    New-SyntheticPdf -OutputPath $inputPdf -PageCount 50 -TargetBytes ([math]::Max(0L, $requestedBytes - $rasterAsciiBytes)) -IncludeRasterImage -RasterWidth 1600 -RasterHeight 2000 | Out-Null
    $results = @()
    for ($index = 1; $index -le $Runs; $index++) {
        $outputRoot = Join-Path $ownedRoot "output-$index"
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
        $cancelMarker = Join-Path $ownedParent ("cancel-performance-$runId-$index.request")
        $logPath = Join-Path $ownedRoot "run-$index.jsonl"
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile','-NonInteractive','-File',(Join-Path $projectRoot '_internal\compress.ps1'),'-InputPath',$inputPdf,'-OutputRoot',$outputRoot,'-LogPath',$logPath,'-StrategyOverride','gs-downsample-180','-SafetyMode','Off','-CancelFile',$cancelMarker,'-StatusJson')) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "Unable to start cancel benchmark run $index." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Start-Sleep -Milliseconds 250
        $watch = [Diagnostics.Stopwatch]::StartNew()
        [IO.File]::WriteAllText($cancelMarker, [DateTimeOffset]::Now.ToString('o'), [Text.UTF8Encoding]::new($false))
        $exited = $process.WaitForExit(8000)
        $forced = $false
        if (-not $exited) {
            $forced = $true
            $process.Kill($true)
            $process.WaitForExit()
        }
        $watch.Stop()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $formalOutputs = @(Get-ChildItem -LiteralPath $outputRoot -Filter '*.compressed.pdf' -File -ErrorAction SilentlyContinue)
        $observedAborted = $stdout -match 'fail_reason=aborted|"reason":"cancel-marker"|cooperative cancel requested'
        $results += [pscustomobject][ordered]@{
            run = $index
            status = if (-not $forced -and $process.ExitCode -eq 1 -and $observedAborted -and $formalOutputs.Count -eq 0 -and $watch.Elapsed.TotalSeconds -le 5) { 'pass' } else { 'fail' }
            cancelToExitMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 3)
            exitCode = $process.ExitCode
            forcedFallback = $forced
            abortedEvidence = $observedAborted
            formalOutputCount = $formalOutputs.Count
            stderrLength = $stderr.Length
        }
        if (Test-Path -LiteralPath $cancelMarker -PathType Leaf) { Remove-Item -LiteralPath $cancelMarker -Force }
    }
    $receipt = [ordered]@{
        schemaVersion = 1
        measuredAtUtc = [DateTime]::UtcNow.ToString('o')
        status = if (@($results | Where-Object status -ne 'pass').Count -eq 0) { 'pass' } else { 'fail' }
        benchmark = 'cooperative-cancel-after-marker'
        fixture = [ordered]@{ actualBytes = (Get-Item -LiteralPath $inputPdf).Length; pageCount = 50; strategy = 'gs-downsample-180' }
        gates = [ordered]@{ gracefulExitMs = 5000; uiIdleReceiptCleanupMs = 8000 }
        results = @($results)
        summary = [ordered]@{
            gracefulPassCount = @($results | Where-Object status -eq 'pass').Count
            forcedFallbackCount = @($results | Where-Object forcedFallback).Count
            forcedFallbackRate = [math]::Round(@($results | Where-Object forcedFallback).Count / [double]$results.Count, 4)
            maxCancelToExitMs = [math]::Round(($results.cancelToExitMs | Measure-Object -Maximum).Maximum, 3)
        }
        limitations = @('This measures the child CLI process from marker creation to exit and output non-commit.', 'WinForms control re-enable and UI-thread idle timing remain manual installed-GUI evidence.')
    }
    $directory = Split-Path -Parent $ReceiptPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [IO.File]::WriteAllText($ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ receiptPath = $ReceiptPath; status = $receipt.status; runs = $Runs }
} finally {
    foreach ($cancelMarker in @(Get-ChildItem -LiteralPath $ownedParent -File -Filter "cancel-performance-$runId-*.request" -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $cancelMarker.FullName -Force }
    if (Test-Path -LiteralPath $ownedRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ownedRoot).Path)
        if (-not $resolved.StartsWith($ownedParent + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup path escaped owned root.' }
        if (-not (Test-Path -LiteralPath $ownerMarker -PathType Leaf)) { throw 'Cleanup owner marker is missing.' }
        $reparse = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($reparse.Count -gt 0) { throw 'Cleanup refused a reparse point.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
