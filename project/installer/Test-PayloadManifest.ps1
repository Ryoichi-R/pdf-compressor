# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [string]$DependencyLedgerPath = (Join-Path $PSScriptRoot 'portable-dependencies.json')
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Get-ManifestProperty {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $null }
    return $Object.PSObject.Properties[$Name].Value
}

function Assert-AllowedProperties {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Context
    )
    foreach ($property in @($Object.PSObject.Properties)) {
        if (-not (@($Allowed) -contains [string]$property.Name)) {
            throw "Unknown $Context property: $($property.Name)"
        }
    }
}

function Assert-NonEmptyString {
    param([object]$Value, [Parameter(Mandatory)][string]$Name)
    if (($Value -isnot [string] -and $Value -isnot [DateTime] -and $Value -isnot [DateTimeOffset]) -or
        [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Manifest field is missing or empty: $Name"
    }
}

function Assert-Sha256 {
    param([object]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -isnot [string] -or $Value -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Manifest field is not a SHA-256 digest: $Name"
    }
}

function Assert-SafeRelativePath {
    param([object]$Value, [Parameter(Mandatory)][string]$Name)
    Assert-NonEmptyString $Value $Name
    $text = [string]$Value
    if ([IO.Path]::IsPathRooted($text) -or
        $text -match '(^|[\\/])\.\.([\\/]|$)' -or
        $text.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or
        $text -match '^[\\/]' -or
        $text -match '^[A-Za-z]:') {
        throw "Unsafe manifest path: $Name"
    }
}

function Assert-ArchiveRecord {
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$Context)
    Assert-AllowedProperties -Object $Record -Allowed @('archive', 'sha256', 'length') -Context $Context
    Assert-NonEmptyString (Get-ManifestProperty $Record 'archive') "$Context.archive"
    if ([string](Get-ManifestProperty $Record 'archive') -notmatch '^[A-Za-z0-9._-]+\.zip$') {
        throw "Invalid archive name: $Context.archive"
    }
    Assert-SafeRelativePath (Get-ManifestProperty $Record 'archive') "$Context.archive"
    Assert-Sha256 (Get-ManifestProperty $Record 'sha256') "$Context.sha256"
    $length = Get-ManifestProperty $Record 'length'
    if ($length -isnot [int] -and $length -isnot [long] -and $length -isnot [double]) {
        throw "Archive length is not numeric: $Context.length"
    }
    if ([long]$length -lt 1 -or [long]$length -gt 262144000) {
        throw "Archive length is outside the payload limit: $Context.length"
    }
}

function Assert-ToolVersions {
    param([Parameter(Mandatory)][object]$ToolVersions, [Parameter(Mandatory)][string]$Context)
    Assert-AllowedProperties -Object $ToolVersions -Allowed @('powershell', 'qpdf', 'poppler', 'ghostscript') -Context $Context
    foreach ($name in @('powershell', 'qpdf', 'poppler', 'ghostscript')) {
        Assert-NonEmptyString (Get-ManifestProperty $ToolVersions $name) "$Context.$name"
    }
}

function Get-CanonicalTreeDigest {
    param([Parameter(Mandatory)][object[]]$Files)
    # Preserve manifest order. The builder signs this exact order so that
    # Windows PowerShell 5.1 and PowerShell 7 do not disagree on path sorting.
    $lines = @($Files | ForEach-Object {
        '{0}|{1}|{2}' -f ([string]$_.path).Replace('\', '/'), ([string]$_.sha256).ToUpperInvariant(), ([long]$_.length)
    })
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes)) -replace '-', '')
    } finally {
        $sha256.Dispose()
    }
}

function Get-RuntimeDependencies {
    param(
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][string]$RuntimeName
    )
    if ([int]$Ledger.schemaVersion -eq 1) { return @($Ledger.dependencies) }
    $runtimeProperty = $Ledger.runtimes.PSObject.Properties[$RuntimeName]
    if ($null -eq $runtimeProperty -or $null -eq $runtimeProperty.Value.dependencies) {
        throw "Dependency ledger has no runtime projection: $RuntimeName"
    }
    return @($runtimeProperty.Value.dependencies)
}

function Assert-ToolVersionsMatchLedger {
    param(
        [Parameter(Mandatory)][object]$ToolVersions,
        [Parameter(Mandatory)][object[]]$Dependencies,
        [Parameter(Mandatory)][string]$Context
    )
    $dependencyMap = @{}
    foreach ($dependency in $Dependencies) { $dependencyMap[[string]$dependency.name] = $dependency }
    foreach ($pair in @(
        [pscustomobject]@{ Tool = 'powershell'; Dependency = 'PowerShell' },
        [pscustomobject]@{ Tool = 'qpdf'; Dependency = 'qpdf' },
        [pscustomobject]@{ Tool = 'poppler'; Dependency = 'Poppler' },
        [pscustomobject]@{ Tool = 'ghostscript'; Dependency = 'Ghostscript' }
    )) {
        if (-not $dependencyMap.ContainsKey($pair.Dependency)) {
            throw "Dependency ledger version is missing: $($pair.Dependency)"
        }
        $expected = [string]$dependencyMap[$pair.Dependency].version
        $actual = [string](Get-ManifestProperty $ToolVersions $pair.Tool)
        $versionPattern = '(?<![0-9])' + [regex]::Escape($expected) + '(?![0-9])'
        if ([string]::IsNullOrWhiteSpace($expected) -or $actual -notmatch $versionPattern) {
            throw "Tool version does not match dependency ledger: $Context.$($pair.Tool)"
        }
    }
}

function Assert-FileInventory {
    param([Parameter(Mandatory)][object]$Files, [Parameter(Mandatory)][string]$Context)
    if ($null -eq $Files -or @($Files).Count -lt 1) {
        throw "Payload file inventory is empty: $Context"
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($Files)) {
        Assert-AllowedProperties -Object $file -Allowed @('path', 'sha256', 'length') -Context "$Context file"
        $path = Get-ManifestProperty $file 'path'
        Assert-SafeRelativePath $path "$Context.path"
        if (-not $seen.Add([string]$path)) { throw "Duplicate or case-colliding payload path: $path" }
        Assert-Sha256 (Get-ManifestProperty $file 'sha256') "$Context.$path.sha256"
        $length = Get-ManifestProperty $file 'length'
        if ($length -isnot [int] -and $length -isnot [long] -and $length -isnot [double]) {
            throw "Payload file length is not numeric: $path"
        }
        if ([long]$length -lt 0) { throw "Payload file length is negative: $path" }
    }
}

function Assert-BuildMetadata {
    param([Parameter(Mandatory)][object]$Build, [Parameter(Mandatory)][string]$Context)
    Assert-AllowedProperties -Object $Build -Allowed @(
        'buildId', 'sourceDigest', 'dependencyDigest', 'sdkVersion',
        'createdAt', 'determinismMode', 'correspondingSource'
    ) -Context $Context
    foreach ($name in @('buildId', 'sdkVersion', 'createdAt')) {
        Assert-NonEmptyString (Get-ManifestProperty $Build $name) "$Context.$name"
    }
    Assert-Sha256 (Get-ManifestProperty $Build 'sourceDigest') "$Context.sourceDigest"
    Assert-Sha256 (Get-ManifestProperty $Build 'dependencyDigest') "$Context.dependencyDigest"
    if ((Get-ManifestProperty $Build 'determinismMode') -ne 'tree-digest-canonical') {
        throw "Unsupported determinism mode: $Context"
    }
    Assert-ArchiveRecord (Get-ManifestProperty $Build 'correspondingSource') "$Context.correspondingSource"
}

$manifestPathFull = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestPathFull -PathType Leaf)) {
    throw "Manifest is missing: $manifestPathFull"
}
$manifest = Get-Content -LiteralPath $manifestPathFull -Raw | ConvertFrom-Json
$dependencyLedgerPathFull = [IO.Path]::GetFullPath($DependencyLedgerPath)
if (-not (Test-Path -LiteralPath $dependencyLedgerPathFull -PathType Leaf)) {
    throw "Dependency ledger is missing: $dependencyLedgerPathFull"
}
$dependencyLedger = Get-Content -LiteralPath $dependencyLedgerPathFull -Raw | ConvertFrom-Json
Assert-AllowedProperties -Object $manifest -Allowed @('schemaVersion', 'productId', 'productVersion', 'releaseId', 'buildId', 'sourceDigest', 'dependencyDigest', 'sdkVersion', 'createdAt', 'determinismMode', 'correspondingSource', 'payloads') -Context 'manifest'

$schemaVersion = [int](Get-ManifestProperty $manifest 'schemaVersion')
if ($schemaVersion -notin @(1, 2, 3) -or (Get-ManifestProperty $manifest 'productId') -ne 'pdf-compressor') {
    throw 'Unsupported or invalid payload manifest.'
}

$payloads = Get-ManifestProperty $manifest 'payloads'
if ($null -eq $payloads) { throw 'Manifest payloads are missing.' }
Assert-AllowedProperties -Object $payloads -Allowed @('win-x64', 'win-arm64') -Context 'payloads'

if ($schemaVersion -eq 2) {
    foreach ($name in @('productVersion', 'buildId', 'sourceDigest', 'dependencyDigest', 'sdkVersion', 'createdAt', 'determinismMode', 'correspondingSource')) {
        if ($null -eq $manifest.PSObject.Properties[$name]) { throw "Manifest v2 field missing: $name" }
    }
    foreach ($name in @('buildId', 'sdkVersion', 'createdAt')) {
        Assert-NonEmptyString (Get-ManifestProperty $manifest $name) "manifest.$name"
    }
    Assert-Sha256 (Get-ManifestProperty $manifest 'sourceDigest') 'manifest.sourceDigest'
    Assert-Sha256 (Get-ManifestProperty $manifest 'dependencyDigest') 'manifest.dependencyDigest'
    if ((Get-ManifestProperty $manifest 'determinismMode') -ne 'tree-digest-canonical') { throw 'Unsupported determinism mode.' }
    Assert-ArchiveRecord (Get-ManifestProperty $manifest 'correspondingSource') 'manifest.correspondingSource'
}
if ($schemaVersion -eq 3) {
    foreach ($name in @('productVersion', 'releaseId')) {
        Assert-NonEmptyString (Get-ManifestProperty $manifest $name) "manifest.$name"
    }
}

$expectedArchitecture = if ($Runtime -eq 'win-x64') { 'x64' } else { 'arm64' }
$advertised = @($payloads.PSObject.Properties)
if ($advertised.Count -lt 1) { throw 'Manifest does not advertise any payload.' }
foreach ($entry in $advertised) {
    $payload = $entry.Value
    $runtimeName = $entry.Name
    if ($schemaVersion -eq 1) {
        Assert-AllowedProperties -Object $payload -Allowed @('archive', 'sha256', 'length', 'files') -Context "payloads.$runtimeName"
    } elseif ($schemaVersion -eq 2) {
        Assert-AllowedProperties -Object $payload -Allowed @('architecture', 'archive', 'sha256', 'length', 'treeDigest', 'toolVersions', 'files') -Context "payloads.$runtimeName"
    } else {
        Assert-AllowedProperties -Object $payload -Allowed @('architecture', 'archive', 'sha256', 'length', 'treeDigest', 'toolVersions', 'files', 'build') -Context "payloads.$runtimeName"
    }
    $payloadArchiveRecord = [pscustomobject]@{
        archive = Get-ManifestProperty $payload 'archive'
        sha256 = Get-ManifestProperty $payload 'sha256'
        length = Get-ManifestProperty $payload 'length'
    }
    Assert-ArchiveRecord $payloadArchiveRecord "payloads.$runtimeName"
    Assert-FileInventory (Get-ManifestProperty $payload 'files') "payloads.$runtimeName.files"
    if ($schemaVersion -ge 2) {
        $architecture = Get-ManifestProperty $payload 'architecture'
        if ($architecture -notin @('x64', 'arm64')) { throw "Unsupported payload architecture: $runtimeName" }
        $expectedForEntry = if ($runtimeName -eq 'win-x64') { 'x64' } else { 'arm64' }
        if ($architecture -ne $expectedForEntry) { throw "Runtime and architecture do not match: $runtimeName" }
        Assert-Sha256 (Get-ManifestProperty $payload 'treeDigest') "payloads.$runtimeName.treeDigest"
        $toolVersions = Get-ManifestProperty $payload 'toolVersions'
        Assert-ToolVersions $toolVersions "payloads.$runtimeName.toolVersions"
        $calculatedTreeDigest = Get-CanonicalTreeDigest @((Get-ManifestProperty $payload 'files'))
        if ($calculatedTreeDigest -ne (Get-ManifestProperty $payload 'treeDigest')) {
            throw "Payload tree digest mismatch: $runtimeName"
        }
        $runtimeDependencies = Get-RuntimeDependencies -Ledger $dependencyLedger -RuntimeName $runtimeName
        Assert-ToolVersionsMatchLedger -ToolVersions $toolVersions -Dependencies $runtimeDependencies -Context "payloads.$runtimeName.toolVersions"
    }
    if ($schemaVersion -eq 3) {
        Assert-BuildMetadata (Get-ManifestProperty $payload 'build') "payloads.$runtimeName.build"
    }
}

$selectedProperty = $payloads.PSObject.Properties[$Runtime]
if ($null -eq $selectedProperty) { throw "Runtime is not present in manifest: $Runtime" }
$selectedPayload = $selectedProperty.Value
$selectedBuild = if ($schemaVersion -eq 3) { Get-ManifestProperty $selectedPayload 'build' } elseif ($schemaVersion -eq 2) { $manifest } else { $null }

[pscustomobject]@{
    Valid = $true
    Runtime = $Runtime
    SchemaVersion = $schemaVersion
    Architecture = if ($schemaVersion -ge 2) { [string](Get-ManifestProperty $selectedPayload 'architecture') } else { $null }
    BuildId = if ($null -ne $selectedBuild) { [string](Get-ManifestProperty $selectedBuild 'buildId') } else { $null }
    Payload = $selectedPayload
    Build = $selectedBuild
}
