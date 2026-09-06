# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Non-destructive environment and capability diagnostics.
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$JsonOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DiagnosticsDir = $PSScriptRoot
$script:DiagnosticsToolRoot = Split-Path -Parent $script:DiagnosticsDir
. (Join-Path $script:DiagnosticsDir 'path-guard.ps1')
. (Join-Path $script:DiagnosticsDir 'tool-resolver.ps1')
. (Join-Path $script:DiagnosticsDir 'tool-capabilities.ps1')
. (Join-Path $script:DiagnosticsDir 'diagnostic-messages.ps1')

function Test-DiagnosticWriteTarget {
    param([Parameter(Mandatory)][string]$Path,[switch]$External)
    $result = [ordered]@{ path = $Path; writable = $false; reason = $null }
    try {
        if ($External) { Assert-OutputPathLocal -TargetPath $Path | Out-Null } else { Assert-WritePathInsideTool -TargetPath $Path | Out-Null }
        $dir = if (Test-Path -LiteralPath $Path -PathType Container) { $Path } else { Split-Path -Parent $Path }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $probe = Join-Path $dir ('.pdfcomp-write-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType File -Path $probe -Force | Out-Null
        Remove-Item -LiteralPath $probe -Force
        $result.writable = $true
    } catch { $result.reason = $_.Exception.Message }
    return [pscustomobject]$result
}

function Get-PdfCompressorDiagnostics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolRoot,[object]$Capabilities,[string]$OutputRoot,[string]$WorkRoot,[string]$LogPath)
    $cap = if ($Capabilities) { $Capabilities } else { Get-ToolCapabilities }
    $checks = [ordered]@{}
    $checks.output = Test-DiagnosticWriteTarget -Path $OutputRoot -External:([bool]($OutputRoot -and $OutputRoot -ne (Join-Path $ToolRoot 'output')))
    $checks.work = Test-DiagnosticWriteTarget -Path $WorkRoot
    $checks.log = Test-DiagnosticWriteTarget -Path $LogPath
    $entries = @()
    if ($cap.entries -is [System.Collections.IDictionary]) {
        foreach ($pair in $cap.entries.GetEnumerator()) {
            $entry = $pair.Value
            $entries += [pscustomobject]@{ id = [string]$pair.Key; found = [bool]$entry.found; version = $entry.version; reason = $entry.reason }
        }
    } else {
        foreach ($property in $cap.entries.PSObject.Properties) {
            $entry = $property.Value
            if ($entry -and $entry.PSObject.Properties['found']) {
                $entries += [pscustomobject]@{ id = $property.Name; found = [bool]$entry.found; version = $entry.version; reason = $entry.reason }
            }
        }
    }
    return [pscustomobject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        os = [System.Environment]::OSVersion.VersionString
        powershell = $PSVersionTable.PSVersion.ToString()
        build_id = if ($env:PDF_COMPRESSOR_BUILD_ID) { [string]$env:PDF_COMPRESSOR_BUILD_ID } else { 'source' }
        safe_ready = [bool]$cap.safe_ready
        missing_required = @($cap.missing_required)
        tools = @($entries)
        write_checks = $checks
        telemetry = 'none'
        pdf_content_external = $false
    }
}

if (-not $env:PDFCOMP_SKIP_MAIN) {
    try {
        $root = $script:DiagnosticsToolRoot
        $outputRoot = Join-Path $root 'output'
        $workRoot = Join-Path $root '_work'
        $logPath = Join-Path $outputRoot 'compress.log.jsonl'
        $report = Get-PdfCompressorDiagnostics -ToolRoot $root -OutputRoot $outputRoot -WorkRoot $workRoot -LogPath $logPath
        $json = $report | ConvertTo-Json -Depth 12
        if ($OutputPath) {
            Assert-WritePathInsideTool -TargetPath $OutputPath | Out-Null
            $parent = Split-Path -Parent $OutputPath
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
        }
        Write-Output $json
        if (-not $JsonOnly) {
            if ($report.safe_ready) { Write-Host '[OK] Required PDF compression capabilities are available.' -ForegroundColor Green }
            else { Write-Host ("[WARN] Required capabilities are missing: {0}" -f (@($report.missing_required) -join ', ')) -ForegroundColor Yellow }
        }
        if (-not $report.safe_ready) { exit 2 }
        exit 0
    } catch [PathGuardException] {
        Write-Error $_.Exception.Message
        exit 5
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
