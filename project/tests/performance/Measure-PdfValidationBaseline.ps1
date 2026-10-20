[CmdletBinding()]
param(
    [ValidateRange(5, 30)][int]$MeasuredRuns = 5,
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..')).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $ReceiptPath = Join-Path $projectRoot "_work\performance-validation-baseline-$stamp.json"
}
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if (-not $ReceiptPath.StartsWith($repositoryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReceiptPath must be inside the repository root.'
}

$internalRoot = Join-Path $projectRoot '_internal'
. (Join-Path $internalRoot 'tool-resolver.ps1')
. (Join-Path $internalRoot 'analyze_pdf.ps1')
. (Join-Path $internalRoot 'pdf-structure.ps1')
. (Join-Path $internalRoot 'inspect_pdf_features.ps1')
. (Join-Path $internalRoot 'safety-policy.ps1')
. (Join-Path $internalRoot 'validate_output.ps1')
. (Join-Path $projectRoot 'tests\support\New-SyntheticPdf.ps1')

$tools = [ordered]@{
    qpdf = Find-ToolExecutable -Name 'qpdf'
    pdfinfo = Find-ToolExecutable -Name 'pdfinfo'
    pdfimages = Find-ToolExecutable -Name 'pdfimages'
}
foreach ($entry in $tools.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        throw "Required performance tool is unavailable: $($entry.Key)"
    }
}

$runId = [Guid]::NewGuid().ToString('N')
$workRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot "_work\performance-$runId"))
$workParent = [IO.Path]::GetFullPath((Join-Path $projectRoot '_work')).TrimEnd('\')
if (-not $workRoot.StartsWith($workParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Performance work path escaped the owned work root.'
}
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$ownerMarker = Join-Path $workRoot '.pdf-compressor-performance-owned'
[IO.File]::WriteAllText($ownerMarker, $runId, [Text.UTF8Encoding]::new($false))

function Invoke-MeasuredValidationPass {
    param([Parameter(Mandatory)][string]$InputPdf, [Parameter(Mandatory)][string]$CandidatePdf)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $metrics = Get-PdfMetrics -PdfPath $InputPdf -PdfInfoExe $tools.pdfinfo -PdfImagesExe $tools.pdfimages
    if ($metrics.error) { throw "Preflight metrics failed: $($metrics.error)" }
    $beforeStructure = Get-PdfStructureSnapshot -PdfPath $InputPdf -PdfInfoExe $tools.pdfinfo -QpdfExe $tools.qpdf -PageCount ([int]$metrics.pageCount)
    $beforeFeatures = Get-PdfFeatures -PdfPath $InputPdf -QpdfExe $tools.qpdf
    $afterStructure = Get-PdfStructureSnapshot -PdfPath $CandidatePdf -PdfInfoExe $tools.pdfinfo -QpdfExe $tools.qpdf -PageCount ([int]$metrics.pageCount)
    $afterFeatures = Get-PdfFeatures -PdfPath $CandidatePdf -QpdfExe $tools.qpdf
    $validation = Validate-CompressedPdf -InputPdf $InputPdf -CandidatePdf $CandidatePdf -QpdfExe $tools.qpdf -PdfInfoExe $tools.pdfinfo -BeforeStructure $beforeStructure -AfterStructure $afterStructure -BeforeFeatures $beforeFeatures -AfterFeatures $afterFeatures -SafetyMode Safe
    $watch.Stop()
    if (-not $validation.accepted) { throw "Validation benchmark was not accepted: $($validation.status)" }
    return [math]::Round($watch.Elapsed.TotalMilliseconds, 3)
}

try {
    $inputPdf = Join-Path $workRoot 'input-10mib-50page.pdf'
    $candidatePdf = Join-Path $workRoot 'candidate.pdf'
    New-SyntheticPdf -OutputPath $inputPdf -PageCount 50 -TargetBytes 10MB -IncludeRasterImage | Out-Null
    & $tools.qpdf '--object-streams=generate' '--' $inputPdf $candidatePdf
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $candidatePdf -PathType Leaf)) {
        throw "qpdf candidate preparation failed with exit code $LASTEXITCODE."
    }

    $warmupMs = Invoke-MeasuredValidationPass -InputPdf $inputPdf -CandidatePdf $candidatePdf
    $samples = @()
    for ($index = 1; $index -le $MeasuredRuns; $index++) {
        $samples += Invoke-MeasuredValidationPass -InputPdf $inputPdf -CandidatePdf $candidatePdf
    }
    $sorted = @($samples | Sort-Object)
    $middle = [int][math]::Floor($sorted.Count / 2)
    $medianMs = if ($sorted.Count % 2 -eq 1) {
        [double]$sorted[$middle]
    } else {
        ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
    }
    $receipt = [ordered]@{
        schemaVersion = 1
        measuredAtUtc = [DateTime]::UtcNow.ToString('o')
        status = 'baseline-established'
        benchmark = 'preflight-plus-post-validation'
        fixture = [ordered]@{
            generator = 'tests/support/New-SyntheticPdf.ps1'
            requestedBytes = 10MB
            actualBytes = (Get-Item -LiteralPath $inputPdf).Length
            pageCount = 50
            includesRasterImage = $true
        }
        protocol = [ordered]@{
            warmupRuns = 1
            measuredRuns = $MeasuredRuns
            statistic = 'median'
            subsequentRegressionLimitMultiplier = 1.5
        }
        result = [ordered]@{
            warmupMs = $warmupMs
            samplesMs = @($samples)
            baselineMedianMs = [math]::Round($medianMs, 3)
            subsequentRegressionLimitMs = [math]::Round(1.5 * $medianMs, 3)
        }
        environment = [ordered]@{
            os = [Environment]::OSVersion.VersionString
            processorCount = [Environment]::ProcessorCount
            powershell = $PSVersionTable.PSVersion.ToString()
            qpdf = ((& $tools.qpdf '--version' 2>&1 | Select-Object -First 1) -join '')
            pdfinfo = ((& $tools.pdfinfo '-v' 2>&1 | Select-Object -First 1) -join '')
            toolPaths = $tools
        }
        limitations = @(
            'This establishes B on the current host/toolchain; it does not compare against a prior compatible baseline.',
            'Ghostscript strategy, queue-scale, cancellation, and target-size resource measurements are separate benchmarks.'
        )
    }
    $receiptDirectory = Split-Path -Parent $ReceiptPath
    if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    }
    [IO.File]::WriteAllText($ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ receiptPath = $ReceiptPath; baselineMedianMs = $medianMs; measuredRuns = $MeasuredRuns }
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
