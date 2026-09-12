# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$ForwardArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-InstallPathHash([string]$Path) {
    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
        ) -replace '-', '').Substring(0, 24)
    } finally {
        $sha.Dispose()
    }
}

$installRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$pwsh = Join-Path $installRoot 'runtime\pwsh\pwsh.exe'
$compress = Join-Path $installRoot '_internal\compress.ps1'
if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf) -or
    -not (Test-Path -LiteralPath $compress -PathType Leaf)) {
    Write-Error 'Installed runtime is incomplete.'
    exit 2
}

$hash = Get-InstallPathHash $installRoot
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "pdf-compressor\runtime-state\$hash"
[IO.Directory]::CreateDirectory($stateRoot) | Out-Null
$gate = [Threading.Mutex]::new($false, "Local\PdfCompressor-Update-$hash")
$lease = $null
$ownsGate = $false
try {
    $ownsGate = $gate.WaitOne(0)
    if (-not $ownsGate) {
        Write-Error 'PDF Compressor is being updated. Try again after the update finishes.'
        exit 8
    }
    $leasePath = Join-Path $stateRoot ("lease-{0}-{1}.lock" -f $PID, [Guid]::NewGuid().ToString('N'))
    $lease = [IO.FileStream]::new(
        $leasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::Read, 4096, [IO.FileOptions]::DeleteOnClose)
    $bytes = [Text.Encoding]::UTF8.GetBytes("$hash`n$PID`n")
    $lease.Write($bytes, 0, $bytes.Length)
    $lease.Flush($true)
    $gate.ReleaseMutex()
    $ownsGate = $false

    $env:PDF_COMPRESSOR_INSTALL_ROOT = $installRoot
    $env:PDF_COMPRESSOR_PWSH = $pwsh
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $compress @ForwardArguments
    exit $LASTEXITCODE
} finally {
    if ($ownsGate) {
        try { $gate.ReleaseMutex() } catch [ApplicationException] {}
    }
    if ($lease) { $lease.Dispose() }
    $gate.Dispose()
}
