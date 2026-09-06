# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$VcpkgExe,
    [Parameter(Mandatory)][string]$CmakeExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($path in @($SourceRoot, $BuildRoot, $InstallRoot)) {
    if ([IO.Path]::GetFullPath($path).StartsWith('\\')) { throw "UNC path is not supported: $path" }
}
[IO.Directory]::CreateDirectory($BuildRoot) | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'poppler-vcpkg.json') `
    -Destination (Join-Path $BuildRoot 'vcpkg.json') -Force
$installed = Join-Path $BuildRoot 'vcpkg_installed'
$toolchain = Join-Path (Split-Path ([IO.Path]::GetFullPath($VcpkgExe))) 'scripts\buildsystems\vcpkg.cmake'
if (-not (Test-Path -LiteralPath $toolchain -PathType Leaf)) {
    throw "vcpkg CMake toolchain is missing: $toolchain"
}
& $VcpkgExe install --triplet x64-windows "--x-manifest-root=$BuildRoot" "--x-install-root=$installed"
if ($LASTEXITCODE -ne 0) { throw "vcpkg failed: $LASTEXITCODE" }
$cmakeBuild = Join-Path $BuildRoot 'build-vs'
& $CmakeExe -S $SourceRoot -B $cmakeBuild -G 'Visual Studio 17 2022' -A x64 `
    -DCMAKE_BUILD_TYPE=Release `
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
    "-DVCPKG_INSTALLED_DIR=$installed" `
    "-DCMAKE_INSTALL_PREFIX=$InstallRoot" `
    -DENABLE_CPP=OFF -DENABLE_QT5=OFF -DENABLE_QT6=OFF -DENABLE_GLIB=OFF `
    -DENABLE_GOBJECT_INTROSPECTION=OFF -DENABLE_GTK_DOC=OFF -DENABLE_BOOST=OFF `
    -DENABLE_CAIRO=OFF -DENABLE_NSS3=OFF -DENABLE_GPGME=OFF `
    -DENABLE_LIBCURL=OFF -DENABLE_UTILS=ON -DBUILD_GTK_TESTS=OFF `
    -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DBUILD_CPP_TESTS=OFF `
    -DBUILD_MANUAL_TESTS=OFF
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed: $LASTEXITCODE" }
& $CmakeExe --build $cmakeBuild --config Release --target INSTALL --parallel 8
if ($LASTEXITCODE -ne 0) { throw "Poppler build failed: $LASTEXITCODE" }
Copy-Item -Path (Join-Path $installed 'x64-windows\bin\*.dll') `
    -Destination (Join-Path $InstallRoot 'bin') -Force
& (Join-Path $InstallRoot 'bin\pdfinfo.exe') -v
if ($LASTEXITCODE -ne 0) { throw 'Built pdfinfo failed to start.' }
