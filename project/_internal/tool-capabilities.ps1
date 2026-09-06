# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Individual external-tool capability discovery and requirement checks.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Find-ToolExecutable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'tool-resolver.ps1')
}

function Get-ToolVersionSafe {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $output = @(& $Path '--version' 2>&1 | Select-Object -First 2)
        $text = (($output | ForEach-Object { [string]$_ }) -join ' ').Trim()
        if ($text.Length -gt 160) { $text = $text.Substring(0,160) }
        return $text
    } catch { return 'unknown' }
}

function Get-CapabilityEntry {
    param([Parameter(Mandatory)][string]$Id,[Parameter()][string]$Tool,[Parameter()][string]$Path,[Parameter()][bool]$Required = $false)
    $found = -not [string]::IsNullOrWhiteSpace($Path)
    return [pscustomobject]@{
        id = $Id; tool = $Tool; path = if ($found) { $Path } else { $null }
        found = $found; required = $Required
        version = if ($found) { Get-ToolVersionSafe -Path $Path } else { $null }
        reason = if ($found) { 'available' } else { 'not-found' }
    }
}

function Get-ToolCapabilities {
    [CmdletBinding()]
    param([string]$CachePath)
    $cache = @{}
    if ($CachePath -and (Test-Path -LiteralPath $CachePath -PathType Leaf)) {
        try { $cache = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { $cache = @{} }
    }
    $find = {
        param([string]$Name)
        $extra = @()
        if ($cache -and $cache.ContainsKey($Name)) { $extra = @([string]$cache[$Name]) }
        return Find-ToolExecutable -Name $Name -ExtraCandidates $extra
    }
    $paths = [ordered]@{
        qpdf = & $find 'qpdf'
        pdfinfo = & $find 'pdfinfo'
        pdfimages = & $find 'pdfimages'
        pdfdetach = & $find 'pdfdetach'
        pdfsig = & $find 'pdfsig'
        ghostscript = & $find 'gswin64c'
        ocrmypdf = & $find 'ocrmypdf'
        tesseract = & $find 'tesseract'
    }
    $entries = [ordered]@{}
    $entries.qpdf = Get-CapabilityEntry -Id 'qpdf' -Tool 'qpdf' -Path $paths.qpdf -Required $true
    $entries.pdfinfo = Get-CapabilityEntry -Id 'pdfinfo' -Tool 'pdfinfo' -Path $paths.pdfinfo -Required $true
    $entries.pdfimages = Get-CapabilityEntry -Id 'pdfimages' -Tool 'pdfimages' -Path $paths.pdfimages -Required $true
    $entries.pdfdetach = Get-CapabilityEntry -Id 'pdfdetach' -Tool 'pdfdetach' -Path $paths.pdfdetach
    $entries.pdfsig = Get-CapabilityEntry -Id 'pdfsig' -Tool 'pdfsig' -Path $paths.pdfsig
    $entries.ghostscript = Get-CapabilityEntry -Id 'ghostscript' -Tool 'gswin64c' -Path $paths.ghostscript
    $entries.ocrmypdf = Get-CapabilityEntry -Id 'ocrmypdf' -Tool 'ocrmypdf' -Path $paths.ocrmypdf
    $entries.tesseract = Get-CapabilityEntry -Id 'tesseract' -Tool 'tesseract' -Path $paths.tesseract
    $allRequired = @($entries.qpdf,$entries.pdfinfo,$entries.pdfimages)
    return [pscustomobject]@{
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        entries = $entries
        paths = [pscustomobject]$paths
        safe_ready = [bool]($allRequired.found -notcontains $false)
        missing_required = @($allRequired | Where-Object { -not $_.found } | ForEach-Object { $_.id })
    }
}

function Get-ToolCapability {
    param([Parameter(Mandatory)][object]$Capabilities,[Parameter(Mandatory)][string]$Capability)
    if ($Capabilities.entries -is [System.Collections.IDictionary] -and $Capabilities.entries.Contains($Capability)) { return $Capabilities.entries[$Capability] }
    if ($Capabilities.entries.PSObject.Properties[$Capability]) { return $Capabilities.entries.$Capability }
    return [pscustomobject]@{ id = $Capability; found = $false; reason = 'unknown-capability'; path = $null }
}

function Require-ToolCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Capabilities,
        [Parameter(Mandatory)][string]$Capability,
        [switch]$Throw
    )
    $entry = Get-ToolCapability -Capabilities $Capabilities -Capability $Capability
    $result = [pscustomobject]@{
        capability = $Capability; available = [bool]$entry.found; path = $entry.path
        version = if ($entry.PSObject.Properties['version']) { $entry.version } else { $null }
        reason = if ($entry.found) { 'available' } else { "tool-unavailable:$Capability" }
    }
    if ($Throw -and -not $result.available) { throw "tool-capability: $($result.reason)" }
    return $result
}

function Test-StrategyCapability {
    param([Parameter(Mandatory)][object]$Capabilities,[Parameter(Mandatory)][string]$StrategyId)
    $capability = switch ($StrategyId) {
        'qpdf-lossless' { 'qpdf' }
        'gs-downsample-150' { 'ghostscript' }
        'gs-downsample-180' { 'ghostscript' }
        'gs-downsample-120' { 'ghostscript' }
        'gs-light-regenerate' { 'ghostscript' }
        'gs-raster-low-quality' { 'ghostscript' }
        'gs-raster-readable' { 'ghostscript' }
        default { $null }
    }
    if (-not $capability) { return [pscustomobject]@{ available = $false; reason = 'unknown-strategy'; capability = $null; path = $null } }
    $required = Require-ToolCapability -Capabilities $Capabilities -Capability $capability
    return [pscustomobject]@{ available = $required.available; reason = $required.reason; capability = $capability; path = $required.path }
}
