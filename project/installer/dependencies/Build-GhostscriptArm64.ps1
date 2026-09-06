# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [string]$VsInstallationPath,
    [string]$ExpectedSha256 = '1CDB766DE8DB8F1E589C817F09C5855EA5F65DFC8540E465A69AC14C18416025'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..\..')).TrimEnd('\')

function Assert-WorkspaceWriteTarget([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($resolved -ne $workspaceRoot -and
        -not $resolved.StartsWith($workspaceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside workspaceRoot: $resolved"
    }
    return $resolved
}

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
        return $reader.ReadUInt16()
    } finally {
        $stream.Dispose()
    }
}

if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::Arm64 -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [Runtime.InteropServices.Architecture]::Arm64) {
    throw 'Ghostscript ARM64 must be built by a native ARM64 process on an ARM64 host.'
}

$archive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Source archive is missing: $archive" }
$actualSourceHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualSourceHash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "Ghostscript source hash mismatch. Expected $ExpectedSha256, got $actualSourceHash"
}

$build = Assert-WorkspaceWriteTarget $BuildRoot
$install = Assert-WorkspaceWriteTarget $InstallRoot
$receipt = Assert-WorkspaceWriteTarget $ReceiptPath
foreach ($target in @($build, $install, $receipt)) {
    if (Test-Path -LiteralPath $target) { throw "Refusing to overwrite existing output: $target" }
}

if ([string]::IsNullOrWhiteSpace($VsInstallationPath)) {
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw "vswhere is missing: $vswhere" }
    $VsInstallationPath = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath)
}
$vsRoot = [IO.Path]::GetFullPath($VsInstallationPath)
$vsDevCmd = Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf)) { throw "VsDevCmd.bat is missing: $vsDevCmd" }

$toolset = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if ($null -eq $toolset) { throw 'MSVC toolset is missing.' }
$nmake = Join-Path $toolset.FullName 'bin\HostARM64\arm64\nmake.exe'
$compiler = Join-Path $toolset.FullName 'bin\HostARM64\arm64\cl.exe'
foreach ($tool in @($nmake, $compiler)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "ARM64 build tool is missing: $tool" }
}

[IO.Directory]::CreateDirectory($build) | Out-Null
$tar = (Get-Command tar.exe -ErrorAction Stop).Source
& $tar -xf $archive -C $build
if ($LASTEXITCODE -ne 0) { throw "Ghostscript source extraction failed: $LASTEXITCODE" }
$sourceRoot = Join-Path $build 'ghostscript-10.07.1'
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'psi\msvc.mak') -PathType Leaf)) {
    throw "Extracted Ghostscript source is incomplete: $sourceRoot"
}

$buildOptions = @(
    'WIN64=',
    'DEVSTUDIO=',
    'DONT_HAVE_SSE2=1',
    'OCR_VERSION=0',
    'MSVC_VERSION=17',
    ('MS_TOOLSET_VERSION=' + $toolset.Name)
)
$quotedDevCmd = '"' + $vsDevCmd + '"'
$quotedNmake = '"' + $nmake + '"'
$commandLine = 'call {0} -arch=arm64 -host_arch=arm64 >nul && {1} -f psi\msvc.mak {2}' -f `
    $quotedDevCmd, $quotedNmake, ($buildOptions -join ' ')
Push-Location $sourceRoot
try {
    & $env:ComSpec /d /s /c $commandLine
    if ($LASTEXITCODE -ne 0) { throw "Ghostscript ARM64 build failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

$builtBin = Join-Path $sourceRoot 'bin'
$runtimeFiles = @('gswin64c.exe', 'gswin64.exe', 'gsdll64.dll')
foreach ($name in $runtimeFiles) {
    $path = Join-Path $builtBin $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Expected Ghostscript output is missing: $path" }
    if ((Get-PeMachine $path) -ne 0xAA64) { throw "Ghostscript output is not ARM64: $path" }
}

[IO.Directory]::CreateDirectory((Join-Path $install 'bin')) | Out-Null
foreach ($name in $runtimeFiles) {
    Copy-Item -LiteralPath (Join-Path $builtBin $name) -Destination (Join-Path $install 'bin\' $name)
}
foreach ($directory in @('lib', 'Resource', 'iccprofiles')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $directory) -Destination (Join-Path $install $directory) -Recurse
}

$redist = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+(?:\.\d+)+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'arm64\Microsoft.VC143.CRT\vcruntime140.dll' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($redist)) { throw 'ARM64 vcruntime140.dll redistributable is missing.' }
if ((Get-PeMachine $redist) -ne 0xAA64) { throw "Redistributable is not ARM64: $redist" }
Copy-Item -LiteralPath $redist -Destination (Join-Path $install 'bin\vcruntime140.dll')

$ghostscript = Join-Path $install 'bin\gswin64c.exe'
$reportedVersion = (& $ghostscript --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $reportedVersion -ne '10.07.1') {
    throw "Built Ghostscript version check failed: $reportedVersion"
}
$deviceText = (& $ghostscript -h 2>&1 | Out-String)
foreach ($device in @('pdfwrite', 'pdfimage24')) {
    if ($deviceText -notmatch ('(?m)\b' + [regex]::Escape($device) + '\b')) { throw "Required device is missing: $device" }
}

$fixture = Join-Path $projectRoot 'tests\fixtures\pdf\minimal-text.pdf'
$validationRoot = Join-Path $build 'validation'
[IO.Directory]::CreateDirectory($validationRoot) | Out-Null
$validationOutputs = @(
    [ordered]@{
        device = 'pdfwrite'
        path = Join-Path $validationRoot 'minimal-text-pdfwrite.pdf'
        arguments = @('-sDEVICE=pdfwrite', '-dSAFER', '-dBATCH', '-dNOPAUSE', '-dQUIET', '-sOutputFile={output}', '--', $fixture)
    },
    [ordered]@{
        device = 'pdfimage24'
        path = Join-Path $validationRoot 'minimal-text-pdfimage24.pdf'
        arguments = @('-sDEVICE=pdfimage24', '-r120', '-dJPEGQ=65', '-dSAFER', '-dBATCH', '-dNOPAUSE', '-dQUIET', '-sOutputFile={output}', '--', $fixture)
    }
)
foreach ($validation in $validationOutputs) {
    $arguments = @($validation.arguments | ForEach-Object { $_ -replace '\{output\}', [string]$validation.path })
    & $ghostscript @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $validation.path -PathType Leaf)) {
        throw "Ghostscript $($validation.device) validation failed."
    }
}

$inventory = @(Get-ChildItem -LiteralPath $install -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($install.Length + 1).Replace('\', '/')
        length = [long]$_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})
$validationReceipt = @($validationOutputs | ForEach-Object {
    [ordered]@{
        device = $_.device
        outputLength = [long](Get-Item -LiteralPath $_.path).Length
        outputSha256 = (Get-FileHash -LiteralPath $_.path -Algorithm SHA256).Hash
    }
})
$receiptObject = [ordered]@{
    schemaVersion = 1
    status = 'succeeded'
    source = [ordered]@{ version = '10.07.1'; archive = [IO.Path]::GetFileName($archive); sha256 = $actualSourceHash; patches = @() }
    host = [ordered]@{ osArchitecture = 'Arm64'; processArchitecture = 'Arm64' }
    toolchain = [ordered]@{
        visualStudioGeneration = '2022 (17)'
        msvcToolset = $toolset.Name
        compilerFileVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
    }
    buildOptions = $buildOptions
    exclusions = @('SSE2 optimization (x86/x64-specific)', 'Tesseract OCR (unused by PDF Compressor and x86/x64 SIMD-specific)')
    version = $reportedVersion
    requiredDevices = @('pdfwrite', 'pdfimage24')
    validation = $validationReceipt
    files = $inventory
}
$receiptParent = Split-Path -Parent $receipt
if (-not [string]::IsNullOrWhiteSpace($receiptParent)) { [IO.Directory]::CreateDirectory($receiptParent) | Out-Null }
[IO.File]::WriteAllText($receipt, (($receiptObject | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    Status = 'succeeded'
    InstallRoot = $install
    ReceiptPath = $receipt
    Version = $reportedVersion
    ConsoleSha256 = (Get-FileHash -LiteralPath $ghostscript -Algorithm SHA256).Hash
}
