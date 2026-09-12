# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [string]$ExtractTo,
    [switch]$RunDiagnostics
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestValidator = Join-Path $PSScriptRoot 'Test-PayloadManifest.ps1'
$manifestValidation = & $manifestValidator -ManifestPath $ManifestPath -Runtime $Runtime

function Assert-SafeRelativePath([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value) -or $Value -match '(^|[\\/])\.\.([\\/]|$)' -or
        $Value.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
        throw "Unsafe payload path: $Value"
    }
}

function Get-CanonicalTreeDigest([object[]]$Files) {
    # Manifest v2 stores files in the builder's canonical order. Re-sorting here
    # is not portable because Sort-Object differs between Windows PowerShell 5.1
    # and PowerShell 7 for mixed-case paths. Hash the signed order as stored;
    # reordering any entry still changes the digest and is rejected.
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

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE executable: $Path" }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
        return $reader.ReadUInt16()
    } finally { $stream.Dispose() }
}

function Get-PeInfo([string]$Path) {
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return $null }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt $stream.Length - 256) { throw "Invalid PE offset: $Path" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
        $machine = $reader.ReadUInt16()
        $sectionCount = $reader.ReadUInt16()
        $stream.Position += 12
        $optionalHeaderSize = $reader.ReadUInt16()
        $stream.Position += 2
        $optionalStart = $stream.Position
        if ($optionalHeaderSize -lt 2) { return [pscustomobject]@{ Machine = $machine; Managed = $false } }
        $magic = $reader.ReadUInt16()
        $dataDirectoryOffset = if ($magic -eq 0x10B) { 96 } elseif ($magic -eq 0x20B) { 112 } else { return [pscustomobject]@{ Machine = $machine; Managed = $false } }
        $clrDirectoryOffset = $optionalStart + $dataDirectoryOffset + (14 * 8)
        $managed = $false
        if ($clrDirectoryOffset + 8 -le $optionalStart + $optionalHeaderSize -and $clrDirectoryOffset + 8 -le $stream.Length) {
            $stream.Position = $clrDirectoryOffset
            $managed = ($reader.ReadUInt32() -ne 0 -or $reader.ReadUInt32() -ne 0)
        }
        return [pscustomobject]@{ Machine = $machine; Managed = $managed }
    } finally { $stream.Dispose() }
}

function Get-RuntimeSpec([string]$Name) {
    if ($Name -eq 'win-x64') {
        return [pscustomobject]@{ Architecture = 'x64'; PeMachine = 0x8664 }
    }
    if ($Name -eq 'win-arm64') {
        return [pscustomobject]@{ Architecture = 'arm64'; PeMachine = 0xAA64 }
    }
    throw "Unsupported runtime: $Name"
}

function Assert-NativeClosure([string]$Root, [int]$ExpectedMachine) {
    # Ghostscript's upstream bundle may contain an x86 uninstall helper at its
    # root. It is not part of the required runtime closure; scan the executable
    # and library directories that the application actually resolves instead.
    # The official x64 PowerShell tree is already an immutable baseline and is
    # intentionally not re-walked during every install integration test. A
    # native ARM64 candidate must pass the complete PowerShell closure scan.
    $relativeRoots = @('runtime\tools', 'runtime\ghostscript\bin', 'runtime\ghostscript\lib')
    if ($ExpectedMachine -eq 0xAA64) { $relativeRoots += 'runtime\pwsh' }
    foreach ($relativeRoot in $relativeRoots) {
        $rootPath = Join-Path $Root $relativeRoot
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
        foreach ($binary in @(Get-ChildItem -LiteralPath $rootPath -Recurse -File | Where-Object { $_.Extension -in @('.exe', '.dll') })) {
            $info = Get-PeInfo $binary.FullName
            if ($null -eq $info) { continue }
            if ($info.Managed) { continue }
            if ($info.Machine -ne $ExpectedMachine) {
                throw "Native PE architecture mismatch: $($binary.FullName)"
            }
        }
    }
}

$manifestPathFull = [IO.Path]::GetFullPath($ManifestPath)
$manifest = Get-Content -LiteralPath $manifestPathFull -Raw | ConvertFrom-Json
$runtimeSpec = Get-RuntimeSpec $Runtime
$payload = $manifest.payloads.PSObject.Properties[$Runtime].Value
if (-not $payload) { throw "Runtime is not present in manifest: $Runtime" }
$build = $manifestValidation.Build
if ($null -ne $build) {
    Assert-SafeRelativePath $build.correspondingSource.archive
    $sourceArchive = Join-Path (Split-Path $manifestPathFull) $build.correspondingSource.archive
    if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) { throw 'Corresponding source archive is missing.' }
    if ((Get-Item -LiteralPath $sourceArchive).Length -ne [long]$build.correspondingSource.length -or
        (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash -ne $build.correspondingSource.sha256) {
        throw 'Corresponding source archive verification failed.'
    }
}
Assert-SafeRelativePath $payload.archive
$archive = Join-Path (Split-Path $manifestPathFull) $payload.archive
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Archive missing: $archive" }
$archiveItem = Get-Item -LiteralPath $archive
if ($archiveItem.Length -ne [long]$payload.length) { throw 'Archive length mismatch.' }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $payload.sha256) {
    throw 'Archive SHA-256 mismatch.'
}

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $payload.files) {
    Assert-SafeRelativePath $file.path
    if (-not $seen.Add($file.path)) { throw "Duplicate or case-colliding path: $($file.path)" }
}
if ($manifest.schemaVersion -ge 2) {
    if ($payload.architecture -ne $runtimeSpec.Architecture) { throw "Payload architecture metadata is not $($runtimeSpec.Architecture)." }
    if ((Get-CanonicalTreeDigest @($payload.files)) -ne $payload.treeDigest) { throw 'Payload tree digest mismatch.' }
}

if ($ExtractTo) {
    $dest = [IO.Path]::GetFullPath($ExtractTo)
    if (Test-Path -LiteralPath $dest) {
        if (Get-ChildItem -LiteralPath $dest -Force | Select-Object -First 1) {
            throw "Extraction target must be empty: $dest"
        }
    } else {
        [IO.Directory]::CreateDirectory($dest) | Out-Null
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $dest
    $actual = @(Get-ChildItem -LiteralPath $dest -Recurse -File)
    if ($actual.Count -ne @($payload.files).Count) { throw 'Extracted file count mismatch.' }
    foreach ($file in $payload.files) {
        $path = [IO.Path]::GetFullPath((Join-Path $dest $file.path))
        if (-not $path.StartsWith($dest.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Extracted path escaped staging root: $($file.path)"
        }
        $item = Get-Item -LiteralPath $path
        if ($item.Length -ne [long]$file.length -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) {
            throw "Extracted file verification failed: $($file.path)"
        }
    }
    foreach ($required in @(
        'PdfCompressor.App.exe', 'compress.bat', '_internal\gui.ps1',
        '_internal\compress.ps1', '_internal\installed-cli.ps1',
        'runtime\pwsh\pwsh.exe', 'runtime\tools\qpdf.exe',
        'runtime\tools\pdfinfo.exe', 'runtime\tools\pdfimages.exe',
        'runtime\ghostscript\bin\gswin64c.exe', 'LICENSE', 'THIRD-PARTY-NOTICES.md'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $dest $required) -PathType Leaf)) {
            throw "Required payload file is missing: $required"
        }
    }
    foreach ($executable in @(
        'PdfCompressor.App.exe', 'runtime\pwsh\pwsh.exe', 'runtime\tools\qpdf.exe',
        'runtime\tools\pdfinfo.exe', 'runtime\tools\pdfimages.exe', 'runtime\ghostscript\bin\gswin64c.exe'
    )) {
        if ((Get-PeMachine (Join-Path $dest $executable)) -ne $runtimeSpec.PeMachine) { throw "Executable architecture mismatch: $executable" }
    }
    Assert-NativeClosure $dest $runtimeSpec.PeMachine
    if ($RunDiagnostics) {
        $diagnosticRoot = Join-Path $dest '_work'
        if (-not (Test-Path -LiteralPath $diagnosticRoot -PathType Container)) {
            [IO.Directory]::CreateDirectory($diagnosticRoot) | Out-Null
        }
        $diagnosticPath = Join-Path $diagnosticRoot 'launcher-diagnostics.json'
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $dest 'PdfCompressor.App.exe'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.ArgumentList.Add('--diagnostics')
        $start.ArgumentList.Add($diagnosticPath)
        $process = [Diagnostics.Process]::Start($start)
        if (-not $process.WaitForExit(30000)) { try { $process.Kill($true) } catch {}; throw 'Launcher diagnostics timed out.' }
        if ($process.ExitCode -ne 0) { throw "Launcher diagnostics failed with exit code $($process.ExitCode)." }
        if (-not (Test-Path -LiteralPath $diagnosticPath -PathType Leaf)) { throw 'Launcher diagnostics did not create the expected report.' }
        $diagnostic = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json
        if (-not $diagnostic.safe_ready -or $diagnostic.telemetry -ne 'none' -or $diagnostic.pdf_content_external) {
            throw 'Launcher diagnostics did not satisfy the installed runtime contract.'
        }
        if ($null -ne $build -and $diagnostic.build_id -ne $build.buildId) {
            throw 'Launcher build id does not match the manifest.'
        }
        Remove-Item -LiteralPath $diagnosticPath -Force
    }
}
[pscustomobject]@{ Valid = $true; Runtime = $Runtime; Archive = $archive; SchemaVersion = $manifest.schemaVersion; BuildId = if ($null -ne $build) { $build.buildId } else { $null } }
