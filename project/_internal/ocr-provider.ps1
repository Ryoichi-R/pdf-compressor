# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Optional OCR provider contract. Base compression never requires it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OcrCapabilities {
    [CmdletBinding()]
    param([object]$Capabilities)
    $entry = $null
    if ($Capabilities -and $Capabilities.entries.PSObject.Properties['ocrmypdf']) { $entry = $Capabilities.entries.ocrmypdf }
    if (-not $entry -or -not $entry.found) {
        return [pscustomobject]@{ provider = 'ocrmypdf'; path = $null; found = $false; version = $null; available_languages = @(); can_rotate = $false; can_deskew = $false; supported = $false; reason = 'ocr-provider-not-found' }
    }
    $langs = @()
    try {
        $tesseract = if ($Capabilities.entries.PSObject.Properties['tesseract']) { $Capabilities.entries.tesseract } else { $null }
        if ($tesseract -and $tesseract.found) {
            $lines = @(& $tesseract.path '--list-langs' 2>&1)
            $langs = @($lines | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -notmatch 'Available languages' -and $_ -notmatch '^List' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    } catch { $langs = @() }
    return [pscustomobject]@{ provider = 'ocrmypdf'; path = $entry.path; found = $true; version = $entry.version; available_languages = @($langs); can_rotate = $true; can_deskew = $true; supported = $true; reason = 'available' }
}

function ConvertTo-OcrLanguageList {
    param([string[]]$Languages)
    $allowed = @('jpn','eng','deu','fra','spa','chi_sim','chi_tra','kor')
    $list = @($Languages | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($list.Count -eq 0) { throw 'ocr: at least one language is required.' }
    foreach ($lang in $list) { if ($allowed -notcontains $lang) { throw "ocr: unsupported language '$lang'." } }
    return @($list | Select-Object -Unique)
}

function Test-OcrRequest {
    param([Parameter(Mandatory)][object]$OcrCapabilities,[Parameter(Mandatory)][string[]]$Languages)
    $normalized = ConvertTo-OcrLanguageList -Languages $Languages
    if (-not $OcrCapabilities.supported) { return [pscustomobject]@{ allowed = $false; reason = 'ocr-provider-not-found'; languages = $normalized } }
    $missing = @($normalized | Where-Object { $OcrCapabilities.available_languages.Count -gt 0 -and $OcrCapabilities.available_languages -notcontains $_ })
    if ($missing.Count -gt 0) { return [pscustomobject]@{ allowed = $false; reason = "ocr-language-unavailable:$($missing -join ',')"; languages = $normalized } }
    return [pscustomobject]@{ allowed = $true; reason = 'available'; languages = $normalized }
}

function Invoke-OcrProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$OcrCapabilities,
        [Parameter(Mandatory)][string]$InputPdf,
        [Parameter(Mandatory)][string]$OutputPdf,
        [Parameter(Mandatory)][string[]]$Languages,
        [ValidateSet('skip','redo','force')][string]$Mode = 'skip',
        [switch]$Rotate,
        [switch]$Deskew
    )
    $request = Test-OcrRequest -OcrCapabilities $OcrCapabilities -Languages $Languages
    if (-not $request.allowed) { return [pscustomobject]@{ success = $false; status = 'unavailable'; reason = $request.reason; exit_code = $null } }
    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('--output-type'); $args.Add('pdf')
    if ($Mode -eq 'force') { $args.Add('--force') } elseif ($Mode -eq 'redo') { $args.Add('--redo-ocr') } else { $args.Add('--skip-text') }
    if ($Rotate) { $args.Add('--rotate-pages') }
    if ($Deskew) { $args.Add('--deskew') }
    $args.Add('-l'); $args.Add(($request.languages -join '+'))
    $args.Add($InputPdf); $args.Add($OutputPdf)
    try {
        $out = @(& $OcrCapabilities.path @args 2>&1)
        $rc = [int]$LASTEXITCODE
        return [pscustomobject]@{ success = ($rc -eq 0 -and (Test-Path -LiteralPath $OutputPdf)); status = if ($rc -eq 0) { 'applied' } else { 'fail' }; reason = if ($rc -eq 0) { 'ok' } else { 'ocr-provider-failed' }; exit_code = $rc; output = (($out -join "`n") | ForEach-Object { if ($_.Length -gt 1024) { $_.Substring(0,1024) } else { $_ } }) }
    } catch { return [pscustomobject]@{ success = $false; status = 'fail'; reason = 'ocr-provider-exception'; exit_code = $null; output = $_.Exception.Message } }
}
