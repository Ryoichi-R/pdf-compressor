# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$X64BaselineRoot,
    [Parameter(Mandatory)][string]$Arm64CandidateRoot,
    [Parameter(Mandatory)][string]$OutputCandidateRoot,
    [ValidateSet('dual-runtime', 'x64-only', 'arm64-only')][string]$Profile = 'dual-runtime'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$manifestValidator = Join-Path $PSScriptRoot 'Test-PayloadManifest.ps1'
$entryRenderer = Join-Path $PSScriptRoot 'New-PayloadEntryBat.ps1'

function Assert-PathUnderProject([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($full -eq $projectRoot -or -not $full.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must remain under the PDF Compressor project root: $full"
    }
    return $full
}

function Get-Property([object]$Object, [string]$Name) {
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $null }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-ArchiveHashRecord([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        return [ordered]@{ sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash; length = [long]$item.Length }
    }
    throw "Expected file: $Path"
}

function Get-SourceArchive([object]$Manifest, [object]$Payload) {
    if ([int]$Manifest.schemaVersion -eq 3) { return $Payload.build.correspondingSource }
    return $Manifest.correspondingSource
}

function Convert-PayloadForV3([object]$Manifest, [object]$Payload, [object]$Build, [string]$ArchiveName, [object]$SourceRecord) {
    $files = @(
        foreach ($file in @($Payload.files)) {
            [ordered]@{ path = [string]$file.path; sha256 = [string]$file.sha256; length = [long]$file.length }
        }
    )
    return [ordered]@{
        architecture = [string]$Payload.architecture
        archive = $ArchiveName
        sha256 = [string]$Payload.sha256
        length = [long]$Payload.length
        treeDigest = [string]$Payload.treeDigest
        toolVersions = [ordered]@{
            powershell = [string]$Payload.toolVersions.powershell
            qpdf = [string]$Payload.toolVersions.qpdf
            poppler = [string]$Payload.toolVersions.poppler
            ghostscript = [string]$Payload.toolVersions.ghostscript
        }
        files = $files
        build = [ordered]@{
            buildId = [string]$Build.buildId
            sourceDigest = [string]$Build.sourceDigest
            dependencyDigest = [string]$Build.dependencyDigest
            sdkVersion = [string]$Build.sdkVersion
            createdAt = [string]$Build.createdAt
            determinismMode = [string]$Build.determinismMode
            correspondingSource = [ordered]@{
                archive = [string]$SourceRecord.archive
                sha256 = [string]$SourceRecord.sha256
                length = [long]$SourceRecord.length
            }
        }
    }
}

function Get-ReleaseId([string]$X64BuildId, [string]$Arm64BuildId) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$X64BuildId|$Arm64BuildId")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return 'pdfc-release-' + (([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16).ToLowerInvariant()) } finally { $sha.Dispose() }
}

$x64Root = Assert-PathUnderProject $X64BaselineRoot
$arm64Root = Assert-PathUnderProject $Arm64CandidateRoot
$outputRoot = Assert-PathUnderProject $OutputCandidateRoot
if (Test-Path -LiteralPath $outputRoot) { throw "Output candidate already exists: $outputRoot" }
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$succeeded = $false
try {

$inputRoots = @($x64Root, $arm64Root)
$beforeInputHashes = @{}
foreach ($root in $inputRoots) {
    $manifestPath = Join-Path $root 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Candidate manifest is missing: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $runtime = if ($root -eq $x64Root) { 'win-x64' } else { 'win-arm64' }
    $validation = & $manifestValidator -ManifestPath $manifestPath -Runtime $runtime
    if (-not $validation.Valid) { throw "Input manifest validation failed: $runtime" }
    $payload = $manifest.payloads.PSObject.Properties[$runtime].Value
    $source = Get-SourceArchive $manifest $payload
    foreach ($relative in @('payload-manifest.json', $payload.archive, $source.archive)) {
        $path = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Candidate artifact is missing: $path" }
        $beforeInputHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
}

$runtimeInputs = [ordered]@{}
foreach ($runtime in @('win-x64', 'win-arm64')) {
    $root = if ($runtime -eq 'win-x64') { $x64Root } else { $arm64Root }
    $manifest = Get-Content -LiteralPath (Join-Path $root 'payload-manifest.json') -Raw | ConvertFrom-Json
    $payload = $manifest.payloads.PSObject.Properties[$runtime].Value
    $build = if ([int]$manifest.schemaVersion -eq 3) { $payload.build } else { $manifest }
    $source = Get-SourceArchive $manifest $payload
    $archiveName = "pdf-compressor-$runtime.zip"
    $sourceName = "pdf-compressor-corresponding-source-$runtime.zip"
    $inputArchive = Join-Path $root $payload.archive
    $inputSource = Join-Path $root $source.archive
    $archiveRecord = Get-ArchiveHashRecord $inputArchive
    if ($archiveRecord.sha256 -ne [string]$payload.sha256 -or $archiveRecord.length -ne [long]$payload.length) {
        throw "Payload archive does not match its manifest: $runtime"
    }
    $sourceActual = Get-ArchiveHashRecord $inputSource
    if ($sourceActual.sha256 -ne [string]$source.sha256 -or $sourceActual.length -ne [long]$source.length) {
        throw "Corresponding source archive does not match its manifest: $runtime"
    }
    Copy-Item -LiteralPath $inputArchive -Destination (Join-Path $outputRoot $archiveName)
    Copy-Item -LiteralPath $inputSource -Destination (Join-Path $outputRoot $sourceName)
    $sourceForManifest = [ordered]@{ archive = $sourceName; sha256 = $sourceActual.sha256; length = $sourceActual.length }
    $runtimeInputs[$runtime] = [ordered]@{
        Manifest = $manifest
        Payload = $payload
        Build = $build
        Source = $sourceForManifest
        ArchiveName = $archiveName
    }
}

$x64 = $runtimeInputs['win-x64']
$arm64 = $runtimeInputs['win-arm64']
if ([string]$x64.Manifest.productVersion -ne [string]$arm64.Manifest.productVersion) {
    throw 'Runtime candidates have different product versions.'
}
$manifest = [ordered]@{
    schemaVersion = 3
    productId = 'pdf-compressor'
    productVersion = [string]$x64.Manifest.productVersion
    releaseId = Get-ReleaseId ([string]$x64.Build.buildId) ([string]$arm64.Build.buildId)
    payloads = [ordered]@{
        'win-x64' = Convert-PayloadForV3 $x64.Manifest $x64.Payload $x64.Build $x64.ArchiveName $x64.Source
        'win-arm64' = Convert-PayloadForV3 $arm64.Manifest $arm64.Payload $arm64.Build $arm64.ArchiveName $arm64.Source
    }
}
$manifestPath = Join-Path $outputRoot 'payload-manifest.json'
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))

foreach ($runtime in @('win-x64', 'win-arm64')) {
    $validation = & $manifestValidator -ManifestPath $manifestPath -Runtime $runtime
    if (-not $validation.Valid) { throw "Composed manifest structural validation failed: $runtime" }
}

$profilesRoot = Join-Path $outputRoot 'profiles'
foreach ($profile in @('x64-only', 'arm64-only', 'dual-runtime')) {
    $profilePath = Join-Path $profilesRoot $profile
    [IO.Directory]::CreateDirectory($profilePath) | Out-Null
    $rendered = Join-Path $profilePath 'root-entry.bat'
    & $entryRenderer -Profile $profile -OutputPath $rendered | Out-Null
}

$afterInputHashes = @{}
foreach ($path in $beforeInputHashes.Keys) { $afterInputHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
foreach ($path in $beforeInputHashes.Keys) {
    if ($beforeInputHashes[$path] -ne $afterInputHashes[$path]) { throw "Input candidate was modified: $path" }
}

$manifestHash = Get-ArchiveHashRecord $manifestPath
$payloadReceipt = [ordered]@{}
foreach ($runtime in @('win-x64', 'win-arm64')) {
    $payloadReceipt[$runtime] = [ordered]@{
        archive = Get-ArchiveHashRecord (Join-Path $outputRoot "pdf-compressor-$runtime.zip")
        correspondingSource = Get-ArchiveHashRecord (Join-Path $outputRoot "pdf-compressor-corresponding-source-$runtime.zip")
    }
}
$profileReceipt = [ordered]@{}
foreach ($profile in @('x64-only', 'arm64-only', 'dual-runtime')) {
    $path = Join-Path $profilesRoot "$profile\root-entry.bat"
    $profileReceipt[$profile] = [ordered]@{ sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; length = [long](Get-Item -LiteralPath $path).Length }
}
$receipt = [ordered]@{
    schemaVersion = 1
    status = 'candidate-composed'
    canonicalPayloadModified = $false
    sourceCandidates = @($x64Root, $arm64Root)
    manifestSha256 = $manifestHash.sha256
    manifestLength = $manifestHash.length
    payloads = $payloadReceipt
    profiles = $profileReceipt
    createdAt = [DateTimeOffset]::Now.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $outputRoot 'release-composition-receipt.json'), (($receipt | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
$result = [pscustomobject]@{ Valid = $true; CandidateRoot = $outputRoot; Manifest = $manifestPath; ManifestSha256 = $manifestHash.sha256 }
$succeeded = $true
$result
} finally {
    if (-not $succeeded -and (Test-Path -LiteralPath $outputRoot -PathType Container)) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
    }
}
