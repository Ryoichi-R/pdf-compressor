# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Run all Pester tests under project/tests/.
.EXAMPLE
    pwsh _internal/run-tests.ps1
.EXAMPLE
    pwsh _internal/run-tests.ps1 -Suite E2E -AllowMissingExternalTools
#>

[CmdletBinding()]
param(
    [string[]]$Filter = @('*.Tests.ps1'),
    [string]$TestRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests'),
    [ValidateSet('Unit','Integration','E2E','All')]
    [string]$Suite = 'Unit',
    [string[]]$Tag = @(),
    [string[]]$ExcludeTag = @(),
    [switch]$AllowMissingExternalTools,
    [switch]$CodeCoverage,
    [string]$CoverageManifest = (Join-Path $PSScriptRoot 'data\coverage-targets.json'),
    [string]$CoverageOutput = (Join-Path (Split-Path -Parent $PSScriptRoot) 'coverage\coverage.xml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' })) {
    Write-Host '[ERROR] Pester 5+ is required. Install: Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0' -ForegroundColor Red
    exit 2
}

Import-Module Pester -MinimumVersion 5.0.0 -Force

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$testRootFull = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
if ($testRootFull -ne $projectRoot -and
    -not $testRootFull.StartsWith(
        $projectRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host '[ERROR] TestRoot must remain under the PDF Compressor project root.' -ForegroundColor Red
    exit 2
}
if (-not (Test-Path -LiteralPath $testRootFull -PathType Container)) {
    Write-Host "[ERROR] TestRoot does not exist: $testRootFull" -ForegroundColor Red
    exit 2
}
$testRoot = $testRootFull
$allSpecs = @(
    foreach ($f in $Filter) {
        Get-ChildItem -LiteralPath $testRoot -Recurse -Filter $f -File
    }
) | Sort-Object FullName -Unique
$specs = @($allSpecs | Where-Object {
    $relative = [IO.Path]::GetRelativePath($testRoot, $_.FullName)
    $isE2E = $relative -match '^e2e[\\/]'
    $isIntegration = $relative -match '^integration[\\/]'
    switch ($Suite) {
        'Unit' { -not $isE2E -and -not $isIntegration }
        'Integration' { $isIntegration }
        'E2E' { $isE2E }
        'All' { $true }
    }
})

if ($Suite -in @('E2E','All')) {
    $e2eSpecs = @($allSpecs | Where-Object {
        [IO.Path]::GetRelativePath($testRoot, $_.FullName) -match '^e2e[\\/]'
    })
    if ($e2eSpecs.Count -eq 0) {
        Write-Host '[ERROR] E2E suite has no tests under tests/e2e.' -ForegroundColor Red
        exit 2
    }
    if (-not $AllowMissingExternalTools) {
        . (Join-Path $PSScriptRoot 'tool-resolver.ps1')
        $missingTools = @()
        foreach ($tool in @(
            [pscustomobject]@{ display = 'qpdf'; resolver = 'qpdf' },
            [pscustomobject]@{ display = 'ghostscript'; resolver = 'gswin64c' },
            [pscustomobject]@{ display = 'pdfinfo'; resolver = 'pdfinfo' }
        )) {
            if (-not (Find-ToolExecutable -Name $tool.resolver)) { $missingTools += $tool.display }
        }
        if ($missingTools.Count -gt 0) {
            Write-Host ("[ERROR] E2E requires external tools: {0}. Use -AllowMissingExternalTools only for local skip development." -f ($missingTools -join ', ')) -ForegroundColor Red
            exit 2
        }
    }
}

if ($specs.Count -eq 0) {
    Write-Host "[INFO] No specs matched: $($Filter -join ', ')"
    exit 0
}

$cfg = New-PesterConfiguration
$cfg.Run.Path = $specs.FullName
$cfg.Output.Verbosity = 'Detailed'
$cfg.Run.Exit = $false
$cfg.Run.PassThru = $true
$coverageOutputFull = $null
$coverageThreshold = $null
if ($Tag.Count -gt 0) { $cfg.Filter.Tag = $Tag }
if ($ExcludeTag.Count -gt 0) { $cfg.Filter.ExcludeTag = $ExcludeTag }
if ($CodeCoverage) {
    $coverageContract = Get-Content -LiteralPath $CoverageManifest -Raw | ConvertFrom-Json
    $coveragePaths = @($coverageContract.files | ForEach-Object {
        $path = [IO.Path]::GetFullPath((Join-Path $projectRoot $_))
        if (-not $path.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Invalid coverage target: $_" }
        $path
    })
    $coverageOutputFull = [IO.Path]::GetFullPath($CoverageOutput)
    if (-not $coverageOutputFull.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'CoverageOutput must remain under the PDF Compressor project root.'
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $coverageOutputFull)) | Out-Null
    $cfg.CodeCoverage.Enabled = $true
    $cfg.CodeCoverage.Path = $coveragePaths
    $cfg.CodeCoverage.OutputFormat = 'JaCoCo'
    $cfg.CodeCoverage.OutputPath = $coverageOutputFull
    $cfg.CodeCoverage.CoveragePercentTarget = [decimal]$coverageContract.thresholdPercent
    $coverageThreshold = [decimal]$coverageContract.thresholdPercent
}

$previousAllowMissing = $env:PDFCOMP_ALLOW_MISSING_EXTERNAL_TOOLS
try {
    if ($AllowMissingExternalTools) { $env:PDFCOMP_ALLOW_MISSING_EXTERNAL_TOOLS = '1' }
    $res = Invoke-Pester -Configuration $cfg
} finally {
    if ($null -eq $previousAllowMissing) { Remove-Item Env:PDFCOMP_ALLOW_MISSING_EXTERNAL_TOOLS -ErrorAction SilentlyContinue }
    else { $env:PDFCOMP_ALLOW_MISSING_EXTERNAL_TOOLS = $previousAllowMissing }
}
if ($res.FailedCount -gt 0) {
    exit 1
}
if ($CodeCoverage) {
    if (-not (Test-Path -LiteralPath $coverageOutputFull -PathType Leaf)) {
        Write-Host '[ERROR] Coverage report was not produced.' -ForegroundColor Red
        exit 1
    }
    [xml]$coverageXml = Get-Content -LiteralPath $coverageOutputFull -Raw
    $counter = $coverageXml.SelectSingleNode('/report/counter[@type="INSTRUCTION"]')
    if ($null -eq $counter) { Write-Host '[ERROR] Coverage report has no aggregate instruction counter.' -ForegroundColor Red; exit 1 }
    $missed = [long]$counter.GetAttribute('missed')
    $covered = [long]$counter.GetAttribute('covered')
    $percent = if (($missed + $covered) -gt 0) { [decimal](100.0 * $covered / ($missed + $covered)) } else { [decimal]0 }
    Write-Host ("[COVERAGE] covered={0} missed={1} percent={2:N2} target={3:N2}" -f $covered,$missed,$percent,$coverageThreshold)
    if ($percent -lt $coverageThreshold) { Write-Host '[ERROR] Tier C0 coverage target was not met.' -ForegroundColor Red; exit 1 }
}
exit 0
