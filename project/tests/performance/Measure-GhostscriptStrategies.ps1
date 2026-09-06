[CmdletBinding()]
param(
    [ValidateRange(10, 300)][int]$TimeoutSeconds = 120,
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..')).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $ReceiptPath = Join-Path $projectRoot "_work\performance-ghostscript-strategies-$stamp.json"
}
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if (-not $ReceiptPath.StartsWith($repositoryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReceiptPath must be inside the repository root.'
}

$internalRoot = Join-Path $projectRoot '_internal'
. (Join-Path $internalRoot 'tool-resolver.ps1')
. (Join-Path $projectRoot 'tests\support\New-SyntheticPdf.ps1')
$ghostscript = Find-ToolExecutable -Name 'gswin64c'
$qpdf = Find-ToolExecutable -Name 'qpdf'
if (-not $ghostscript) { throw 'Ghostscript is unavailable.' }
if (-not $qpdf) { throw 'qpdf is unavailable.' }

$strategies = @(
    [pscustomobject]@{ id = 'gs-downsample-120'; dpi = 120 },
    [pscustomobject]@{ id = 'gs-downsample-150'; dpi = 150 },
    [pscustomobject]@{ id = 'gs-downsample-180'; dpi = 180 },
    [pscustomobject]@{ id = 'gs-light-regenerate'; dpi = 220 }
)
$runId = [Guid]::NewGuid().ToString('N')
$workParent = [IO.Path]::GetFullPath((Join-Path $projectRoot '_work')).TrimEnd('\')
$workRoot = [IO.Path]::GetFullPath((Join-Path $workParent "ghostscript-performance-$runId"))
if (-not $workRoot.StartsWith($workParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Performance work path escaped the owned work root.'
}
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$ownerMarker = Join-Path $workRoot '.pdf-compressor-performance-owned'
[IO.File]::WriteAllText($ownerMarker, $runId, [Text.UTF8Encoding]::new($false))

function Get-DirectoryByteCount {
    param([Parameter(Mandatory)][string]$Path)
    return [long](Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

try {
    $inputPdf = Join-Path $workRoot 'input-10mib-50page-high-dpi.pdf'
    $requestedBytes = 10MB
    $rasterAsciiBytes = 2L * 1600L * 2000L + 1L
    $contentTargetBytes = [math]::Max(0L, $requestedBytes - $rasterAsciiBytes)
    New-SyntheticPdf -OutputPath $inputPdf -PageCount 50 -TargetBytes $contentTargetBytes -IncludeRasterImage -RasterWidth 1600 -RasterHeight 2000 | Out-Null
    $inputBytes = (Get-Item -LiteralPath $inputPdf).Length
    $results = @()
    foreach ($strategy in $strategies) {
        $outputPdf = Join-Path $workRoot ($strategy.id + '.pdf')
        $stderrPath = Join-Path $workRoot ($strategy.id + '.stderr.txt')
        $stdoutPath = Join-Path $workRoot ($strategy.id + '.stdout.txt')
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $ghostscript
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
                '-sDEVICE=pdfwrite', '-dSAFER', '-dBATCH', '-dNOPAUSE', '-dQUIET',
                '-dCompatibilityLevel=1.7', '-dColorConversionStrategy=/LeaveColorUnchanged',
                '-dDownsampleColorImages=true', '-dDownsampleGrayImages=true', '-dDownsampleMonoImages=false',
                "-dColorImageResolution=$($strategy.dpi)", "-dGrayImageResolution=$($strategy.dpi)",
                '-dAutoRotatePages=/None', "-sOutputFile=$outputPdf", '--', $inputPdf
            )) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $watch = [Diagnostics.Stopwatch]::StartNew()
        if (-not $process.Start()) { throw "Failed to start Ghostscript for $($strategy.id)." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $peakWorkingSet = 0L
        $peakWorkBytes = Get-DirectoryByteCount -Path $workRoot
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
            $peakWorkBytes = [math]::Max($peakWorkBytes, (Get-DirectoryByteCount -Path $workRoot))
            Start-Sleep -Milliseconds 25
        }
        $process.WaitForExit()
        $watch.Stop()
        [IO.File]::WriteAllText($stdoutPath, $stdoutTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderrPath, $stderrTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
        $outputBytes = if (Test-Path -LiteralPath $outputPdf -PathType Leaf) { (Get-Item -LiteralPath $outputPdf).Length } else { 0L }
        $qpdfExit = $null
        if ($outputBytes -gt 0) {
            & $qpdf '--check' '--' $outputPdf *> $null
            $qpdfExit = [int]$LASTEXITCODE
        }
        $results += [pscustomobject][ordered]@{
            strategyId = $strategy.id
            dpi = $strategy.dpi
            status = if ($timedOut) { 'timeout' } elseif ($process.ExitCode -eq 0 -and $qpdfExit -in @(0, 3)) { 'pass' } else { 'fail' }
            exitCode = if ($timedOut) { $null } else { $process.ExitCode }
            qpdfCheckExitCode = $qpdfExit
            wallMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 3)
            peakWorkingSetBytes = $peakWorkingSet
            peakOwnedWorkBytes = $peakWorkBytes
            outputBytes = $outputBytes
            outputRatio = if ($inputBytes -gt 0) { [math]::Round([double]$outputBytes / [double]$inputBytes, 6) } else { $null }
        }
    }
    $receipt = [ordered]@{
        schemaVersion = 1
        measuredAtUtc = [DateTime]::UtcNow.ToString('o')
        status = if (@($results | Where-Object status -ne 'pass').Count -eq 0) { 'pass' } else { 'fail' }
        benchmark = 'ghostscript-strategy-resource-matrix'
        fixture = [ordered]@{ requestedBytes = $requestedBytes; actualBytes = $inputBytes; pageCount = 50; rasterWidth = 1600; rasterHeight = 2000 }
        limits = [ordered]@{ perStrategyTimeoutSeconds = $TimeoutSeconds }
        results = @($results)
        environment = [ordered]@{
            os = [Environment]::OSVersion.VersionString
            processorCount = [Environment]::ProcessorCount
            powershell = $PSVersionTable.PSVersion.ToString()
            ghostscriptPath = $ghostscript
            qpdf = ((& $qpdf '--version' 2>&1 | Select-Object -First 1) -join '')
        }
        limitations = @('Peak working set samples the direct Ghostscript process every 25 ms.', 'Peak owned work bytes covers the benchmark work directory and is not a whole-volume measurement.')
    }
    $receiptDirectory = Split-Path -Parent $ReceiptPath
    if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }
    [IO.File]::WriteAllText($ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ receiptPath = $ReceiptPath; status = $receipt.status; strategies = $results.Count }
} finally {
    if (Test-Path -LiteralPath $workRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $workRoot).Path)
        if (-not $resolved.StartsWith($workParent + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup path escaped owned work root.' }
        if (-not (Test-Path -LiteralPath $ownerMarker -PathType Leaf)) { throw 'Performance cleanup owner marker is missing.' }
        $reparse = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($reparse.Count -gt 0) { throw 'Performance cleanup refused a reparse point.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
