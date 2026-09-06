# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    payload ビルドに必要な依存アーカイブを公式配布元から取得し、固定 SHA-256 で検証する。
.DESCRIPTION
    portable-dependencies.json が runtime ごとに固定している SHA-256 を正本とし、
    download-sources.json の URL から取得する。照合前のアーカイブは一時ファイルのまま
    扱い、一致した場合だけ所定の名前へ移す。不一致の場合は取得物を削除して throw する。

    このスクリプトは展開もビルドも行わない。取得と検証だけを担当する。
.EXAMPLE
    pwsh -File Get-PortableDependencies.ps1 -Runtime win-x64 -DestinationRoot ..\..\third-party-source
.EXAMPLE
    pwsh -File Get-PortableDependencies.ps1 -Runtime win-x64 -DestinationRoot D:\deps -WhatIfList
#>

[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [Parameter(Mandatory)][string]$DestinationRoot,
    [string]$LedgerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'portable-dependencies.json'),
    [string]$SourcesPath = (Join-Path $PSScriptRoot 'download-sources.json'),
    [switch]$IncludeCommonSources,
    [switch]$SkipSignatureVerification,
    [switch]$WhatIfList
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-LocalDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\')) {
        throw "UNC・device path は取得先に指定できません: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -notmatch '^[A-Za-z]:\\$') {
        throw "取得先は単一ドライブレター配下である必要があります: $Path"
    }
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Get-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "必須ファイルが見つかりません: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-RequiredArtifact {
    param(
        [Parameter(Mandatory)]$Ledger,
        [Parameter(Mandatory)][string]$RuntimeName,
        [bool]$WithCommonSources
    )
    $projection = $Ledger.runtimes.PSObject.Properties |
        Where-Object { $_.Name -eq $RuntimeName } |
        Select-Object -First 1
    if (-not $projection) {
        throw "依存台帳に runtime projection がありません: $RuntimeName"
    }

    $required = [ordered]@{}
    foreach ($dependency in @($projection.Value.dependencies)) {
        # artifactPath を持つ entry は、公式配布物ではなく固定ソースからのローカル
        # ビルド成果物である（win-arm64 の qpdf / Poppler / Ghostscript）。取得元 URL は
        # 存在しないため、ダウンロード対象から外して build recipe 側へ委ねる。
        $isLocalBuild = [bool]($dependency.PSObject.Properties.Name -contains 'artifactPath')
        $required[[string]$dependency.artifact] = [pscustomobject]@{
            Artifact  = [string]$dependency.artifact
            Sha256    = ([string]$dependency.sha256).ToUpperInvariant()
            Name      = [string]$dependency.name
            License   = [string]$dependency.license
            Kind      = if ($isLocalBuild) { 'local-build' } else { 'runtime-dependency' }
            LocalPath = if ($isLocalBuild) { [string]$dependency.artifactPath } else { '' }
        }
    }

    if ($WithCommonSources) {
        foreach ($property in $Ledger.commonSources.PSObject.Properties) {
            $source = $property.Value
            $artifact = [string]$source.artifact
            if ($required.Contains($artifact)) { continue }
            $required[$artifact] = [pscustomobject]@{
                Artifact  = $artifact
                Sha256    = ([string]$source.sha256).ToUpperInvariant()
                Name      = [string]$property.Name
                License   = [string]$source.license
                Kind      = 'corresponding-source'
                LocalPath = ''
            }
        }
    }

    return @($required.Values)
}

function Resolve-DownloadUrl {
    param(
        [Parameter(Mandatory)]$Sources,
        [Parameter(Mandatory)][string]$Artifact
    )
    $entry = @($Sources.artifacts | Where-Object { [string]$_.artifact -eq $Artifact })
    if ($entry.Count -ne 1) {
        throw "download-sources.json に一意な URL がありません: $Artifact"
    }
    $url = [string]$entry[0].url
    if (-not $url.StartsWith('https://')) {
        throw "取得 URL は https である必要があります: $Artifact -> $url"
    }
    return $url
}

function Save-VerifiedArtifact {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existing = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($existing -eq $ExpectedSha256) {
            return 'already-present'
        }
        throw "既存ファイルの SHA-256 が台帳と一致しません。手動で確認してください: $Destination"
    }

    # 照合前のバイト列を正規の名前で置かないため、一時ファイルへ落としてから移す。
    $temp = "$Destination.$([Guid]::NewGuid().ToString('N')).part"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $temp -MaximumRedirection 5 -UseBasicParsing
        $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $ExpectedSha256) {
            throw "SHA-256 が台帳と一致しません: $Url`n  expected=$ExpectedSha256`n  actual  =$actual"
        }
        Move-Item -LiteralPath $temp -Destination $Destination
        return 'downloaded'
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) {
            Remove-Item -LiteralPath $temp -Force
        }
    }
}

$destination = Assert-LocalDirectoryPath -Path $DestinationRoot
$ledger = Get-JsonFile -Path $LedgerPath
$sources = Get-JsonFile -Path $SourcesPath
$required = Get-RequiredArtifact -Ledger $ledger -RuntimeName $Runtime -WithCommonSources ([bool]$IncludeCommonSources)

if ($WhatIfList) {
    return @($required | ForEach-Object {
        [pscustomobject]@{
            Artifact = $_.Artifact
            Name     = $_.Name
            License  = $_.License
            Kind     = $_.Kind
            Sha256   = $_.Sha256
            Url      = if ($_.Kind -eq 'local-build') { '' } else { Resolve-DownloadUrl -Sources $sources -Artifact $_.Artifact }
        }
    })
}

[IO.Directory]::CreateDirectory($destination) | Out-Null

$results = foreach ($item in $required) {
    if ($item.Kind -eq 'local-build') {
        Write-Host "[SKIP] $($item.Artifact) は固定ソースからのローカルビルド成果物です。build recipe で生成してください（台帳の記録先: $($item.LocalPath)）。"
        continue
    }
    $url = Resolve-DownloadUrl -Sources $sources -Artifact $item.Artifact
    $target = Join-Path $destination $item.Artifact
    $state = Save-VerifiedArtifact -Url $url -Destination $target -ExpectedSha256 $item.Sha256
    Write-Host "[OK] $($item.Artifact) ($state)"
    [pscustomobject]@{
        Artifact = $item.Artifact
        Name     = $item.Name
        License  = $item.License
        Kind     = $item.Kind
        Sha256   = $item.Sha256
        Path     = $target
        State    = $state
    }
}

# Poppler は公式 detached signature を持つ。SHA-256 だけでは台帳自体が誤っていた場合を
# 検出できないため、公式 release signer の fingerprint まで遡って検証する。
# 署名・公開鍵・keyring は installer/dependency-evidence/ に SHA-256 固定で同梱済みで、
# Test-PopplerSourceSignature.ps1 が既定でそれらを参照する。取得は不要。
$popplerArtifact = @($results | Where-Object { $_.Name -eq 'Poppler' })
if ($popplerArtifact.Count -eq 1 -and -not $SkipSignatureVerification) {
    $verifier = Join-Path $PSScriptRoot 'Test-PopplerSourceSignature.ps1'
    Write-Host '[INFO] Poppler の detached signature を検証します。'
    & $verifier -ArchivePath $popplerArtifact[0].Path | Out-Null
    Write-Host '[OK] Poppler signature verified.'
} elseif ($SkipSignatureVerification) {
    Write-Warning 'Poppler の署名検証をスキップしました。release 用の取得では使用しないでください。'
}

$results
