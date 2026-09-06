# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [Parameter(Mandatory)][string]$VcpkgRoot,
    [Parameter(Mandatory)][string]$CmakeExe,
    [Parameter(Mandatory)][string]$NinjaExe,
    [string]$VcpkgDownloadsRoot,
    [string]$VsInstallationPath,
    [string]$ExpectedSha256 = '6CBA2F9F2CD887D905FAEB99E0E51A307B217920D1BBF3E9CFBB2E8178A2DEDA'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..')).TrimEnd('\')

function Assert-RepositoryWriteTarget([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($resolved -ne $repositoryRoot -and
        -not $resolved.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside repositoryRoot: $resolved"
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

function Quote-CmdArgument([string]$Value) {
    if ($Value.Contains('"')) { throw "Double quote is not supported in command argument: $Value" }
    return '"' + $Value + '"'
}

if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::Arm64 -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [Runtime.InteropServices.Architecture]::Arm64) {
    throw 'qpdf ARM64 must be built by a native ARM64 process on an ARM64 host.'
}

$archive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Source archive is missing: $archive" }
$actualSourceHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualSourceHash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "qpdf source hash mismatch. Expected $ExpectedSha256, got $actualSourceHash"
}

$build = Assert-RepositoryWriteTarget $BuildRoot
$install = Assert-RepositoryWriteTarget $InstallRoot
$receipt = Assert-RepositoryWriteTarget $ReceiptPath
$downloads = if ([string]::IsNullOrWhiteSpace($VcpkgDownloadsRoot)) {
    Join-Path $build 'downloads'
} else {
    Assert-WorkspaceWriteTarget $VcpkgDownloadsRoot
}
foreach ($target in @($build, $install, $receipt)) {
    if (Test-Path -LiteralPath $target) { throw "Refusing to overwrite existing output: $target" }
}
if ($build.Length -gt 100) {
    throw "BuildRoot is too long for reliable Windows native builds ($($build.Length) characters); use a short workspace path."
}

$vcpkg = Join-Path ([IO.Path]::GetFullPath($VcpkgRoot)) 'vcpkg.exe'
$cmake = [IO.Path]::GetFullPath($CmakeExe)
$ninja = [IO.Path]::GetFullPath($NinjaExe)
foreach ($tool in @($vcpkg, $cmake, $ninja)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required build tool is missing: $tool" }
}

if ([string]::IsNullOrWhiteSpace($VsInstallationPath)) {
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw "vswhere is missing: $vswhere" }
    $VsInstallationPath = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath)
}
$vsRoot = [IO.Path]::GetFullPath($VsInstallationPath)
$vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { throw "vcvarsall.bat is missing: $vcvars" }
$toolset = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if ($null -eq $toolset) { throw 'MSVC toolset is missing.' }
$compiler = Join-Path $toolset.FullName 'bin\HostARM64\arm64\cl.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw "ARM64 compiler is missing: $compiler" }

[IO.Directory]::CreateDirectory($build) | Out-Null
[IO.Directory]::CreateDirectory($downloads) | Out-Null
$sourceContainer = Join-Path $build 'src'
[IO.Directory]::CreateDirectory($sourceContainer) | Out-Null
$tar = (Get-Command tar.exe -ErrorAction Stop).Source
& $tar -xf $archive -C $sourceContainer
if ($LASTEXITCODE -ne 0) { throw "qpdf source extraction failed: $LASTEXITCODE" }
$sourceRoot = Join-Path $sourceContainer 'qpdf-12.3.2'
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CMakeLists.txt') -PathType Leaf)) {
    throw "Extracted qpdf source is incomplete: $sourceRoot"
}

$vcpkgInstalled = Join-Path $build 'vi'
& $vcpkg install 'zlib:arm64-windows' 'libjpeg-turbo:arm64-windows' `
    "--x-install-root=$vcpkgInstalled" "--downloads-root=$downloads"
if ($LASTEXITCODE -ne 0) { throw "vcpkg dependency build failed: $LASTEXITCODE" }

$dependencyRoot = Join-Path $vcpkgInstalled 'arm64-windows'
$cmakeBuild = Join-Path $build 'b'
$intermediateInstall = Join-Path $build 'i'
$configureArguments = @(
    '-S', $sourceRoot,
    '-B', $cmakeBuild,
    '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$ninja",
    '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_INSTALL_PREFIX=$intermediateInstall",
    '-DBUILD_SHARED_LIBS=ON',
    '-DBUILD_STATIC_LIBS=OFF',
    '-DBUILD_DOC=OFF',
    '-DINSTALL_EXAMPLES=OFF',
    '-DUSE_IMPLICIT_CRYPTO=OFF',
    '-DREQUIRE_CRYPTO_NATIVE=ON',
    "-DLIBJPEG_H_PATH=$(Join-Path $dependencyRoot 'include')",
    "-DLIBJPEG_LIB_PATH=$(Join-Path $dependencyRoot 'lib\jpeg.lib')",
    "-DZLIB_H_PATH=$(Join-Path $dependencyRoot 'include')",
    "-DZLIB_LIB_PATH=$(Join-Path $dependencyRoot 'lib\z.lib')",
    '-DCMAKE_C_FLAGS=/utf-8',
    '-DCMAKE_CXX_FLAGS=/utf-8 /EHsc'
)
$configureCommand = (@(Quote-CmdArgument $cmake) + @($configureArguments | ForEach-Object { Quote-CmdArgument $_ })) -join ' '
$buildCommand = '{0} --build {1} --target install --parallel 8' -f (Quote-CmdArgument $cmake), (Quote-CmdArgument $cmakeBuild)
$commandLine = 'call {0} arm64 >nul && {1} && {2}' -f (Quote-CmdArgument $vcvars), $configureCommand, $buildCommand
& $env:ComSpec /d /s /c $commandLine
if ($LASTEXITCODE -ne 0) { throw "qpdf ARM64 build failed: $LASTEXITCODE" }

[IO.Directory]::CreateDirectory($install) | Out-Null
$runtimeSources = [ordered]@{
    'qpdf.exe' = Join-Path $intermediateInstall 'bin\qpdf.exe'
    'qpdf30.dll' = Join-Path $intermediateInstall 'bin\qpdf30.dll'
    'z.dll' = Join-Path $dependencyRoot 'bin\z.dll'
    'jpeg62.dll' = Join-Path $dependencyRoot 'bin\jpeg62.dll'
}
$redistDirectory = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+(?:\.\d+)+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'arm64\Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'msvcp140.dll') -PathType Leaf } |
    Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($redistDirectory)) { throw 'ARM64 MSVC redistributable directory is missing.' }
$runtimeSources['msvcp140.dll'] = Join-Path $redistDirectory 'msvcp140.dll'
$runtimeSources['vcruntime140.dll'] = Join-Path $redistDirectory 'vcruntime140.dll'
foreach ($entry in $runtimeSources.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) { throw "Runtime dependency is missing: $($entry.Value)" }
    if ((Get-PeMachine $entry.Value) -ne 0xAA64) { throw "Runtime dependency is not ARM64: $($entry.Value)" }
    Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $install $entry.Key)
}

$qpdf = Join-Path $install 'qpdf.exe'
$reportedVersion = (& $qpdf --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $reportedVersion -notmatch '(?m)^qpdf version 12\.3\.2\r?$') {
    throw "Built qpdf version check failed: $reportedVersion"
}
$fixture = Join-Path $projectRoot 'tests\fixtures\pdf\minimal-text.pdf'
$validationRoot = Join-Path $build 'validation'
[IO.Directory]::CreateDirectory($validationRoot) | Out-Null
$outputPdf = Join-Path $validationRoot 'minimal-text-object-streams.pdf'
& $qpdf --check $fixture
if ($LASTEXITCODE -ne 0) { throw 'qpdf source fixture check failed.' }
& $qpdf --object-streams=generate $fixture $outputPdf
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPdf -PathType Leaf)) {
    throw 'qpdf fixture transformation failed.'
}
& $qpdf --check $outputPdf
if ($LASTEXITCODE -ne 0) { throw 'qpdf transformed fixture check failed.' }

$inventory = @(Get-ChildItem -LiteralPath $install -File | Sort-Object Name | ForEach-Object {
    [ordered]@{
        path = $_.Name
        machine = ('0x{0:X4}' -f (Get-PeMachine $_.FullName))
        length = [long]$_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})
$receiptObject = [ordered]@{
    schemaVersion = 1
    status = 'succeeded'
    source = [ordered]@{ version = '12.3.2'; archive = [IO.Path]::GetFileName($archive); sha256 = $actualSourceHash; patches = @() }
    host = [ordered]@{ osArchitecture = 'Arm64'; processArchitecture = 'Arm64' }
    toolchain = [ordered]@{
        visualStudioGeneration = '2022 (17)'
        msvcToolset = $toolset.Name
        compilerFileVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        cmakeVersion = (& $cmake --version | Select-Object -First 1)
        ninjaSha256 = (Get-FileHash -LiteralPath $ninja -Algorithm SHA256).Hash
        vcpkgExecutableSha256 = (Get-FileHash -LiteralPath $vcpkg -Algorithm SHA256).Hash
    }
    buildOptions = @('Ninja', 'Release', '/utf-8', '/EHsc', 'native crypto', 'shared libqpdf')
    dependencies = @('zlib:arm64-windows', 'libjpeg-turbo:arm64-windows', 'Microsoft.VC143.CRT:arm64')
    version = '12.3.2'
    validation = [ordered]@{
        sourceCheck = 'passed'
        objectStreamsTransform = 'passed'
        outputLength = [long](Get-Item -LiteralPath $outputPdf).Length
        outputSha256 = (Get-FileHash -LiteralPath $outputPdf -Algorithm SHA256).Hash
    }
    files = $inventory
}
$receiptParent = Split-Path -Parent $receipt
if (-not [string]::IsNullOrWhiteSpace($receiptParent)) { [IO.Directory]::CreateDirectory($receiptParent) | Out-Null }
[IO.File]::WriteAllText($receipt, (($receiptObject | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    Status = 'succeeded'
    InstallRoot = $install
    ReceiptPath = $receipt
    Version = '12.3.2'
    QpdfSha256 = (Get-FileHash -LiteralPath $qpdf -Algorithm SHA256).Hash
}
