# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Manifest creation, validation, and input enumeration.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ManifestPropertyValue {
    param([object]$Object,[string]$Name,[object]$Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function New-DefaultInputManifest {
    return [pscustomobject]@{
        version = '1.0'
        defaults = [pscustomobject]@{
            mode = 'auto'; safety_mode = 'Safe'; target_bytes = $null
            ocr = [pscustomobject]@{ enabled = $false; languages = @() }
        }
        items = @()
    }
}

function ConvertTo-AbsolutePdfInput {
    param([Parameter(Mandatory)][string]$InputPath)
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'manifest: input_path is empty.' }
    $resolved = [System.IO.Path]::GetFullPath($InputPath)
    $check = Assert-InputPathReadable -InputPath $resolved
    if ($check.kind -ne 'file') { throw "manifest: item is not a PDF file ($resolved)." }
    return $check.path
}

function New-InputManifestFromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [string]$Mode = 'auto',
        [string]$SafetyMode = 'Safe',
        [Nullable[long]]$TargetBytes,
        [switch]$EnableOcr,
        [string[]]$OcrLanguages = @(),
        [switch]$AllowSignedPdf,
        [switch]$AllowFullPageRaster
    )
    if ($Mode -notin @('auto','high-quality','standard','minimum-size')) { throw "manifest: invalid mode '$Mode'." }
    if ($SafetyMode -notin @('Safe','Warn','Off')) { throw "manifest: invalid safety mode '$SafetyMode'." }
    if ($null -ne $TargetBytes -and [long]$TargetBytes -le 0) { throw 'manifest: target_bytes must be positive.' }
    $check = Assert-InputPathReadable -InputPath ([System.IO.Path]::GetFullPath($InputPath)) -AllowDirectory
    $files = if ($check.kind -eq 'directory') {
        @(Get-ChildItem -LiteralPath $check.path -Recurse -File -Filter '*.pdf' -ErrorAction Stop |
            Where-Object { $_.Name -notlike '*.compressed.pdf' } |
            ForEach-Object { ConvertTo-AbsolutePdfInput -InputPath $_.FullName })
    } else { @($check.path) }
    $manifest = New-DefaultInputManifest
    $manifest.defaults.mode = $Mode
    $manifest.defaults.safety_mode = $SafetyMode
    $manifest.defaults.target_bytes = if ($null -ne $TargetBytes) { [long]$TargetBytes } else { $null }
    $manifest.defaults.ocr = [pscustomobject]@{ enabled = [bool]$EnableOcr; languages = @($OcrLanguages) }
    $seen = @{}
    $items = foreach ($file in $files) {
        $key = $file.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [pscustomobject]@{
            item_id = [Guid]::NewGuid().ToString('N')
            input_path = $file; mode = $null; safety_mode = $null; target_bytes = $null
            ocr = $null; output_root = $null; allow_signed_pdf = [bool]$AllowSignedPdf
            allow_full_page_raster = [bool]$AllowFullPageRaster
        }
    }
    $manifest.items = @($items)
    return $manifest
}

function Read-InputManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowRiskConsents,
        [string]$WorkRoot,
        [string]$ConsentNonce
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "manifest: file not found '$Path'." }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try { $source = $raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "manifest: invalid JSON: $($_.Exception.Message)" }
    $schemaPath = Join-Path $PSScriptRoot 'data\input-manifest.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw "manifest: schema file not found '$schemaPath'." }
    if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) { throw 'manifest: Test-Json is required. PowerShell 7+ is required.' }
    try {
        if (-not (Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'manifest: JSON does not match input-manifest.schema.json.' }
    } catch { throw "manifest: schema validation failed: $($_.Exception.Message)" }
    if ([string]$source.version -notmatch '^1\.[0-9]+$') { throw "manifest: unsupported version '$($source.version)'." }
    $defaults = Get-ManifestPropertyValue -Object $source -Name 'defaults'
    $items = @(Get-ManifestPropertyValue -Object $source -Name 'items' -Default @())
    if ($items.Count -gt 1000) { throw 'manifest: item limit is 1000.' }
    $manifestFullPath = [System.IO.Path]::GetFullPath($Path)
    $riskConsent = Get-ManifestPropertyValue -Object $source -Name 'risk_consent'
    $consentNonceValue = [string](Get-ManifestPropertyValue -Object $riskConsent -Name 'nonce' '')
    $consentWorkDir = [string](Get-ManifestPropertyValue -Object $riskConsent -Name 'work_dir' '')
    $hasRiskFields = @($items | Where-Object {
        [bool](Get-ManifestPropertyValue -Object $_ -Name 'allow_signed_pdf' $false) -or
        [bool](Get-ManifestPropertyValue -Object $_ -Name 'allow_full_page_raster' $false)
    }).Count -gt 0
    if ($hasRiskFields) {
        if (-not $AllowRiskConsents) { throw 'manifest: risk consent requires explicit acceptance.' }
        if ($consentNonceValue -notmatch '^[0-9a-fA-F]{32,}$' -or $consentNonceValue.Length % 2 -ne 0) {
            throw 'manifest: risk consent nonce must be an opaque value of at least 128 bits.'
        }
        if ([string]::IsNullOrWhiteSpace($WorkRoot)) { throw 'manifest: work root is required for risk consent.' }
        $workRootFull = [System.IO.Path]::GetFullPath($WorkRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $manifestParent = [System.IO.Path]::GetDirectoryName($manifestFullPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if (-not $manifestParent.StartsWith($workRootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'manifest: risk consent manifest must be inside the current work root.'
        }
        if (-not [string]::IsNullOrWhiteSpace($consentWorkDir)) {
            $consentWorkDirFull = [System.IO.Path]::GetFullPath($consentWorkDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            if (-not $manifestParent.Equals($consentWorkDirFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'manifest: risk consent work_dir does not match the manifest directory.'
            }
        }
        if ([string]::IsNullOrWhiteSpace($ConsentNonce) -or
            -not $ConsentNonce.Equals($consentNonceValue, [System.StringComparison]::Ordinal)) {
            throw 'manifest: risk consent nonce does not match the current run.'
        }
    }
    $manifest = New-DefaultInputManifest
    $manifest.version = [string]$source.version
    $manifest.defaults.mode = [string](Get-ManifestPropertyValue $defaults 'mode' 'auto')
    $manifest.defaults.safety_mode = [string](Get-ManifestPropertyValue $defaults 'safety_mode' 'Safe')
    $manifest.defaults.target_bytes = Get-ManifestPropertyValue $defaults 'target_bytes'
    if ($null -ne $manifest.defaults.target_bytes -and ([long]$manifest.defaults.target_bytes) -le 0) { throw 'manifest: default target_bytes must be positive.' }
    $defaultOcr = Get-ManifestPropertyValue $defaults 'ocr'
    $manifest.defaults.ocr = [pscustomobject]@{
        enabled = [bool](Get-ManifestPropertyValue $defaultOcr 'enabled' $false)
        languages = @((Get-ManifestPropertyValue $defaultOcr 'languages' @()))
    }
    if ($manifest.defaults.mode -notin @('auto','high-quality','standard','minimum-size')) { throw 'manifest: invalid default mode.' }
    if ($manifest.defaults.safety_mode -notin @('Safe','Warn','Off')) { throw 'manifest: invalid default safety_mode.' }
    $seen = @{}
    $normalizedItems = foreach ($item in $items) {
        $pathValue = [string](Get-ManifestPropertyValue $item 'input_path' '')
        $path = ConvertTo-AbsolutePdfInput -InputPath $pathValue
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $allowSigned = [bool](Get-ManifestPropertyValue $item 'allow_signed_pdf' $false)
        $allowRaster = [bool](Get-ManifestPropertyValue $item 'allow_full_page_raster' $false)
        $itemMode = Get-ManifestPropertyValue $item 'mode'
        $itemSafety = Get-ManifestPropertyValue $item 'safety_mode'
        $itemTarget = Get-ManifestPropertyValue $item 'target_bytes'
        if ($null -ne $itemMode -and [string]$itemMode -notin @('auto','high-quality','standard','minimum-size')) { throw "manifest: invalid item mode for '$path'." }
        if ($null -ne $itemSafety -and [string]$itemSafety -notin @('Safe','Warn','Off')) { throw "manifest: invalid item safety_mode for '$path'." }
        if ($null -ne $itemTarget -and ([long]$itemTarget) -le 0) { throw "manifest: item target_bytes must be positive for '$path'." }
        if (($allowSigned -or $allowRaster) -and -not $AllowRiskConsents) {
            throw "manifest: risk consent for '$path' requires explicit acceptance."
        }
        [pscustomobject]@{
            item_id = [Guid]::NewGuid().ToString('N')
            input_path = $path
            mode = $itemMode
            safety_mode = $itemSafety
            target_bytes = $itemTarget
            ocr = Get-ManifestPropertyValue $item 'ocr'
            output_root = Get-ManifestPropertyValue $item 'output_root'
            allow_signed_pdf = $allowSigned
            allow_full_page_raster = $allowRaster
        }
    }
    $manifest.items = @($normalizedItems)
    return $manifest
}

function Get-ManifestItemSetting {
    param([Parameter(Mandatory)][object]$Item,[Parameter(Mandatory)][object]$Defaults,[Parameter(Mandatory)][string]$Name)
    $value = Get-ManifestPropertyValue $Item $Name
    if ($null -eq $value) { return Get-ManifestPropertyValue $Defaults $Name }
    return $value
}
