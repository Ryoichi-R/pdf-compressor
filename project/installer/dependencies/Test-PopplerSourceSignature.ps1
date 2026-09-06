# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [string]$ArchivePath,
    [string]$SignaturePath,
    [string]$PublicKeyPath,
    [string]$KeyringPath,
    [string]$GpgvPath,
    [string]$ExpectedFingerprint = 'CA262C6C83DE4D2FB28A332A3A6A4DB839EAA6D7',
    [string]$ExpectedArchiveSha256 = '304832F48F8A47FDCA90C6B6D1F684E68F37C10C9A0726F345F4CA9DF4CA01E2',
    [string]$ExpectedSignatureSha256 = 'AAFA340DBBEE102347EAA790B653E72F64C2A22F45E45ACE4953495A6F84BB8D',
    [string]$ExpectedPublicKeySha256 = '44AFB1547E9386BA81022B26E52558B941B80555B7A5A3869AD1C3205612A8D7',
    [string]$ExpectedKeyringSha256 = 'C187635EC18D8B345F9620DD2422805350936987E9415E0543A9D622B8402141'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$evidenceRoot = Join-Path $projectRoot 'installer\dependency-evidence\poppler-26.07.0'
if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = Join-Path $projectRoot 'third-party-source\poppler-26.07.0.tar.xz' }
if ([string]::IsNullOrWhiteSpace($SignaturePath)) { $SignaturePath = Join-Path $evidenceRoot 'poppler-26.07.0.tar.xz.sig' }
if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) { $PublicKeyPath = Join-Path $evidenceRoot 'albert-astals-cid-CA262C6C83DE4D2FB28A332A3A6A4DB839EAA6D7.asc' }
if ([string]::IsNullOrWhiteSpace($KeyringPath)) { $KeyringPath = Join-Path $evidenceRoot 'release-signer-keyring.gpg' }

function Resolve-GnuPgExecutable([string]$Configured, [string]$Name) {
    if (-not [string]::IsNullOrWhiteSpace($Configured)) {
        $full = [IO.Path]::GetFullPath($Configured)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Name executable not found: $full" }
        return $full
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return [IO.Path]::GetFullPath($command.Source) }
    $gitBundled = "C:\Program Files\Git\usr\bin\$Name.exe"
    if (Test-Path -LiteralPath $gitBundled -PathType Leaf) { return $gitBundled }
    throw "$Name executable not found."
}

function Convert-ToGnuPgPath([string]$Path, [string]$Executable) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($Executable -match '(?i)[\\/]Git[\\/]usr[\\/]bin[\\/]gpgv?\.exe$') {
        if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "Unsupported MSYS path: $full" }
        return ('/{0}/{1}' -f $Matches[1].ToLowerInvariant(), $Matches[2].Replace('\', '/'))
    }
    return $full
}

function Assert-FileHash([string]$Path, [string]$Expected, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Label not found: $full" }
    $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    if ($actual -ne $Expected) { throw "$Label SHA-256 mismatch: $actual" }
    return $full
}

if ($ExpectedFingerprint -notmatch '^[0-9A-F]{40}$') { throw 'Expected fingerprint must be 40 uppercase hexadecimal characters.' }
$archive = Assert-FileHash $ArchivePath $ExpectedArchiveSha256 'Poppler source archive'
$signature = Assert-FileHash $SignaturePath $ExpectedSignatureSha256 'Poppler detached signature'
$publicKey = Assert-FileHash $PublicKeyPath $ExpectedPublicKeySha256 'Poppler release public key'
$keyring = Assert-FileHash $KeyringPath $ExpectedKeyringSha256 'Poppler release keyring'
$gpgv = Resolve-GnuPgExecutable $GpgvPath 'gpgv'

$verifyOutput = @(& $gpgv --status-fd 1 --keyring (Convert-ToGnuPgPath $keyring $gpgv) `
        (Convert-ToGnuPgPath $signature $gpgv) (Convert-ToGnuPgPath $archive $gpgv) 2>&1)
if ($LASTEXITCODE -ne 0) { throw "gpgv detached signature verification failed with exit code $LASTEXITCODE." }
$validFingerprints = @(
    $verifyOutput | ForEach-Object {
        if ($_ -match '^\[GNUPG:\] VALIDSIG ([0-9A-F]{40}) ') { $Matches[1] }
    }
)
if ($ExpectedFingerprint -notin $validFingerprints) { throw 'VALIDSIG did not bind to the expected Poppler signer fingerprint.' }

[pscustomobject]@{
    status = 'verified'
    archive = $archive
    archiveSha256 = $ExpectedArchiveSha256
    signature = $signature
    signatureSha256 = $ExpectedSignatureSha256
    publicKey = $publicKey
    publicKeySha256 = $ExpectedPublicKeySha256
    keyringSha256 = $ExpectedKeyringSha256
    signerFingerprint = $ExpectedFingerprint
    gpgv = $gpgv
}
