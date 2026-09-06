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
    [string]$ExpectedSha256 = '304832F48F8A47FDCA90C6B6D1F684E68F37C10C9A0726F345F4CA9DF4CA01E2'
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
    throw 'Poppler ARM64 must be built by a native ARM64 process on an ARM64 host.'
}

$archive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Source archive is missing: $archive" }
$actualSourceHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualSourceHash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "Poppler source hash mismatch. Expected $ExpectedSha256, got $actualSourceHash"
}

$build = Assert-RepositoryWriteTarget $BuildRoot
$install = Assert-RepositoryWriteTarget $InstallRoot
$receipt = Assert-RepositoryWriteTarget $ReceiptPath
$downloads = if ([string]::IsNullOrWhiteSpace($VcpkgDownloadsRoot)) {
    Join-Path $build 'downloads'
} else {
    Assert-RepositoryWriteTarget $VcpkgDownloadsRoot
}
foreach ($target in @($build, $install, $receipt)) {
    if (Test-Path -LiteralPath $target) { throw "Refusing to overwrite existing output: $target" }
}
if ($build.Length -gt 100) {
    throw "BuildRoot is too long for reliable Windows native builds ($($build.Length) characters); use a short workspace path."
}

$vcpkg = Join-Path ([IO.Path]::GetFullPath($VcpkgRoot)) 'vcpkg.exe'
$vcpkgToolchain = Join-Path ([IO.Path]::GetFullPath($VcpkgRoot)) 'scripts\buildsystems\vcpkg.cmake'
$cmake = [IO.Path]::GetFullPath($CmakeExe)
$ninja = [IO.Path]::GetFullPath($NinjaExe)
foreach ($tool in @($vcpkg, $vcpkgToolchain, $cmake, $ninja)) {
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
if ($LASTEXITCODE -ne 0) { throw "Poppler source extraction failed: $LASTEXITCODE" }
$sourceRoot = Join-Path $sourceContainer 'poppler-26.07.0'
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'CMakeLists.txt') -PathType Leaf)) {
    throw "Extracted Poppler source is incomplete: $sourceRoot"
}

$vcpkgInstalled = Join-Path $build 'vi'
$vcpkgPackages = @(
    'freetype:arm64-windows',
    'zlib:arm64-windows',
    'openjpeg:arm64-windows',
    'libjpeg-turbo:arm64-windows',
    'libpng:arm64-windows',
    'tiff:arm64-windows',
    'lcms:arm64-windows'
)
& $vcpkg install @vcpkgPackages "--x-install-root=$vcpkgInstalled" "--downloads-root=$downloads"
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
    "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchain",
    '-DVCPKG_TARGET_TRIPLET=arm64-windows',
    "-DVCPKG_INSTALLED_DIR=$vcpkgInstalled",
    "-DCMAKE_INSTALL_PREFIX=$intermediateInstall",
    '-DCMAKE_C_FLAGS=/utf-8',
    '-DCMAKE_CXX_FLAGS=/utf-8 /EHsc',
    '-DENABLE_CPP=OFF',
    '-DENABLE_QT5=OFF',
    '-DENABLE_QT6=OFF',
    '-DENABLE_GLIB=OFF',
    '-DENABLE_GOBJECT_INTROSPECTION=OFF',
    '-DENABLE_GTK_DOC=OFF',
    '-DENABLE_BOOST=OFF',
    '-DENABLE_NSS3=OFF',
    '-DENABLE_GPGME=OFF',
    '-DENABLE_LIBCURL=OFF',
    '-DENABLE_UTILS=ON',
    '-DBUILD_GTK_TESTS=OFF',
    '-DBUILD_QT5_TESTS=OFF',
    '-DBUILD_QT6_TESTS=OFF',
    '-DBUILD_CPP_TESTS=OFF',
    '-DBUILD_MANUAL_TESTS=OFF'
)
$configureCommand = (@(Quote-CmdArgument $cmake) + @($configureArguments | ForEach-Object { Quote-CmdArgument $_ })) -join ' '
$buildCommand = '{0} --build {1} --target install --parallel 8' -f (Quote-CmdArgument $cmake), (Quote-CmdArgument $cmakeBuild)
$commandLine = 'call {0} arm64 >nul && {1} && {2}' -f (Quote-CmdArgument $vcvars), $configureCommand, $buildCommand
& $env:ComSpec /d /s /c $commandLine
if ($LASTEXITCODE -ne 0) { throw "Poppler ARM64 build failed: $LASTEXITCODE" }

[IO.Directory]::CreateDirectory($install) | Out-Null
$requiredOutputs = @('pdfinfo.exe', 'pdfimages.exe', 'pdftoppm.exe', 'pdfdetach.exe', 'poppler.dll')
foreach ($name in $requiredOutputs) {
    $source = Join-Path $intermediateInstall "bin\$name"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required Poppler output is missing: $source" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $install $name)
}
foreach ($dll in @(Get-ChildItem -LiteralPath (Join-Path $dependencyRoot 'bin') -File -Filter '*.dll')) {
    Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $install $dll.Name)
}
$redistDirectory = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+(?:\.\d+)+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'arm64\Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'msvcp140.dll') -PathType Leaf } |
    Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($redistDirectory)) { throw 'ARM64 MSVC redistributable directory is missing.' }
foreach ($name in @('msvcp140.dll', 'vcruntime140.dll')) {
    Copy-Item -LiteralPath (Join-Path $redistDirectory $name) -Destination (Join-Path $install $name)
}
foreach ($file in @(Get-ChildItem -LiteralPath $install -File)) {
    if ((Get-PeMachine $file.FullName) -ne 0xAA64) { throw "Poppler runtime file is not ARM64: $($file.FullName)" }
}

$pdfinfo = Join-Path $install 'pdfinfo.exe'
$pdfimages = Join-Path $install 'pdfimages.exe'
$pdftoppm = Join-Path $install 'pdftoppm.exe'
$pdfdetach = Join-Path $install 'pdfdetach.exe'
$reportedVersion = (& $pdfinfo -v 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $reportedVersion -notmatch '(?m)^pdfinfo version 26\.07\.0\r?$') {
    throw "Built Poppler version check failed: $reportedVersion"
}
$fixture = Join-Path $projectRoot 'tests\fixtures\pdf\minimal-text.pdf'
$validationRoot = Join-Path $build 'validation'
[IO.Directory]::CreateDirectory($validationRoot) | Out-Null
& $pdfinfo $fixture | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'pdfinfo fixture validation failed.' }
& $pdfimages -list $fixture | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'pdfimages fixture validation failed.' }
$renderPrefix = Join-Path $validationRoot 'minimal-text'
& $pdftoppm -f 1 -singlefile -png $fixture $renderPrefix | Out-Null
$renderOutput = $renderPrefix + '.png'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $renderOutput -PathType Leaf)) {
    throw 'pdftoppm fixture rendering failed.'
}
& $pdfdetach -list $fixture | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'pdfdetach fixture validation failed.' }

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
    source = [ordered]@{ version = '26.07.0'; archive = [IO.Path]::GetFileName($archive); sha256 = $actualSourceHash; patches = @() }
    host = [ordered]@{ osArchitecture = 'Arm64'; processArchitecture = 'Arm64' }
    toolchain = [ordered]@{
        visualStudioGeneration = '2022 (17)'
        msvcToolset = $toolset.Name
        compilerFileVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        cmakeVersion = (& $cmake --version | Select-Object -First 1)
        ninjaSha256 = (Get-FileHash -LiteralPath $ninja -Algorithm SHA256).Hash
        vcpkgExecutableSha256 = (Get-FileHash -LiteralPath $vcpkg -Algorithm SHA256).Hash
    }
    buildOptions = @('Ninja', 'Release', '/utf-8', '/EHsc', 'utils enabled', 'Qt/GLib/CPP/NSS/GPGME/curl disabled')
    dependencies = $vcpkgPackages
    version = '26.07.0'
    validation = [ordered]@{
        pdfinfo = 'passed'
        pdfimages = 'passed'
        pdftoppm = 'passed'
        pdfdetach = 'passed'
        renderedPngLength = [long](Get-Item -LiteralPath $renderOutput).Length
        renderedPngSha256 = (Get-FileHash -LiteralPath $renderOutput -Algorithm SHA256).Hash
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
    Version = '26.07.0'
    PdfinfoSha256 = (Get-FileHash -LiteralPath $pdfinfo -Algorithm SHA256).Hash
}
