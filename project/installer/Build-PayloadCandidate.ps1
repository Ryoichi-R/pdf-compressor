# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [Parameter(Mandatory)][string]$PowerShellRoot,
    [Parameter(Mandatory)][string]$QpdfRoot,
    [Parameter(Mandatory)][string]$PopplerRoot,
    [Parameter(Mandatory)][string]$GhostscriptRoot,
    [string]$CandidateRoot,
    [switch]$KeepFailedStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$dependencyLedger = Join-Path $PSScriptRoot 'portable-dependencies.json'
$entryRenderer = Join-Path $PSScriptRoot 'New-PayloadEntryBat.ps1'
$productVersion = '1.1.0'

if ($Runtime -eq 'win-arm64' -and [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::Arm64) {
    throw 'A win-arm64 candidate must be built and validated on a native ARM64 host.'
}

function Assert-PathUnderProject([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($full -eq $projectRoot -or -not $full.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must remain under the PDF Compressor project root: $full"
    }
    return $full
}

function Get-CanonicalDigest([object[]]$Entries) {
    $lines = @($Entries | Sort-Object path | ForEach-Object {
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

function Get-SourceInventory {
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($relativeRoot in @('_internal', 'src', 'installer', 'licenses')) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $projectRoot $relativeRoot) -File -Recurse -Force)) { $files.Add($file) }
    }
    foreach ($relative in @('Directory.Build.props', 'Directory.Packages.props', 'global.json', 'NuGet.Config', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md')) {
        $files.Add((Get-Item -LiteralPath (Join-Path $projectRoot $relative)))
    }
    return @($files | Where-Object {
            $_.Name -ne 'tool-paths.json' -and
            $_.Extension -notin @('.pdb', '.user') -and
            [IO.Path]::GetRelativePath($projectRoot, $_.FullName).Replace('\', '/') -notmatch '(^|/)(bin|obj)(/|$)' -and
            [IO.Path]::GetRelativePath($projectRoot, $_.FullName).Replace('\', '/') -notmatch '^installer/(candidates|payload|_work|dependency-evidence)(/|$)'
        } |
        Sort-Object FullName -Unique | ForEach-Object {
            [pscustomobject]@{
                path = [IO.Path]::GetRelativePath($projectRoot, $_.FullName).Replace('\', '/')
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                length = [long]$_.Length
            }
        })
}

function Find-RequiredTool([string]$Root, [string]$Name) {
    $match = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Name | Select-Object -First 1
    if (-not $match) { throw "Tool missing: $Name under $Root" }
    return $match.FullName
}

function Get-ToolVersion([string]$Path, [string[]]$Arguments) {
    $output = @(& $Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Tool version command failed: $Path" }
    return (($output | Select-Object -First 2) -join ' ').Trim()
}

function Get-DependencyLedgerObject {
    return Get-Content -LiteralPath $dependencyLedger -Raw | ConvertFrom-Json
}

function Get-RuntimeDependencyRecords([object]$Ledger, [string]$SelectedRuntime) {
    if ([int]$Ledger.schemaVersion -eq 1) { return @($Ledger.dependencies) }
    $runtimeProperty = $Ledger.runtimes.PSObject.Properties[$SelectedRuntime]
    if ($null -eq $runtimeProperty -or $null -eq $runtimeProperty.Value.dependencies) {
        throw "Dependency ledger has no runtime projection: $SelectedRuntime"
    }
    return @($runtimeProperty.Value.dependencies)
}

function Get-DependencyDigest([object]$Ledger, [string]$SelectedRuntime) {
    if ([int]$Ledger.schemaVersion -eq 1) {
        return (Get-FileHash -LiteralPath $dependencyLedger -Algorithm SHA256).Hash
    }
    $runtimeProperty = $Ledger.runtimes.PSObject.Properties[$SelectedRuntime]
    if ($null -eq $runtimeProperty) { throw "Dependency ledger has no runtime: $SelectedRuntime" }
    $projection = [ordered]@{
        runtime = $SelectedRuntime
        architecture = $runtimeProperty.Value.architecture
        dependencies = @($runtimeProperty.Value.dependencies | Sort-Object name)
        vcpkg = $runtimeProperty.Value.vcpkg
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($projection | ConvertTo-Json -Depth 20 -Compress))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '') } finally { $sha.Dispose() }
}

function Get-BuildId {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SelectedRuntime,
        [Parameter(Mandatory)][string]$SourceDigest,
        [Parameter(Mandatory)][string]$DependencyDigest
    )
    $identity = "$Version|$SelectedRuntime|$SourceDigest|$DependencyDigest"
    $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '')
        return 'pdfc-{0}-{1}-{2}' -f $Version, $SelectedRuntime, $digest.Substring(0, 16).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-SingleRuntimeReleaseId([string]$BuildId) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($BuildId)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '')
        return 'pdfc-release-' + $digest.Substring(0, 16).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-DependencyArtifact([object]$Dependency, [string]$DependencyName) {
    $artifact = if ($Dependency.PSObject.Properties['sourceArtifact']) { $Dependency.sourceArtifact } else { $Dependency.artifact }
    $expectedHash = if ($Dependency.PSObject.Properties['sourceSha256']) { $Dependency.sourceSha256 } else { $Dependency.sha256 }
    if ([string]::IsNullOrWhiteSpace([string]$artifact) -or [string]::IsNullOrWhiteSpace([string]$expectedHash)) {
        throw "Dependency source provenance is incomplete: $DependencyName"
    }
    $sourcePath = Join-Path $projectRoot ('third-party-source\' + $artifact)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Corresponding source missing: $artifact" }
    if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $expectedHash) {
        throw "Corresponding source hash mismatch: $DependencyName"
    }
    return $sourcePath
}

function Assert-ToolVersionsMatchLedger([object]$Versions, [object[]]$Dependencies) {
    $map = @{}
    foreach ($dependency in $Dependencies) { $map[[string]$dependency.name] = $dependency }
    foreach ($pair in @(
        [pscustomobject]@{ Name = 'PowerShell'; Output = [string]$Versions.powershell },
        [pscustomobject]@{ Name = 'qpdf'; Output = [string]$Versions.qpdf },
        [pscustomobject]@{ Name = 'Poppler'; Output = [string]$Versions.poppler },
        [pscustomobject]@{ Name = 'Ghostscript'; Output = [string]$Versions.ghostscript }
    )) {
        if (-not $map.ContainsKey($pair.Name)) { throw "Dependency ledger version is missing: $($pair.Name)" }
        $version = [string]$map[$pair.Name].version
        if ([string]::IsNullOrWhiteSpace($version) -or $pair.Output -notmatch [regex]::Escape($version)) {
            throw "Tool version does not match dependency ledger: $($pair.Name)"
        }
    }
}

$sourceInventory = Get-SourceInventory
$sourceDigest = Get-CanonicalDigest $sourceInventory
$dependencyLedgerObject = Get-DependencyLedgerObject
$runtimeDependencies = Get-RuntimeDependencyRecords $dependencyLedgerObject $Runtime
$dependencyDigest = Get-DependencyDigest $dependencyLedgerObject $Runtime
$buildId = Get-BuildId -Version $productVersion -SelectedRuntime $Runtime -SourceDigest $sourceDigest -DependencyDigest $dependencyDigest
$sdkVersion = (& dotnet --version).Trim()
if ($LASTEXITCODE -ne 0) { throw 'dotnet SDK resolution failed.' }

if ([string]::IsNullOrWhiteSpace($CandidateRoot)) {
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $CandidateRoot = Join-Path $PSScriptRoot "candidates\$runId"
}
$candidate = Assert-PathUnderProject $CandidateRoot
if (Test-Path -LiteralPath $candidate) { throw "Candidate root already exists: $candidate" }
[IO.Directory]::CreateDirectory($candidate) | Out-Null
$stage = Join-Path $candidate 'stage'
$launcherOut = Join-Path $candidate 'launcher'
[IO.Directory]::CreateDirectory($stage) | Out-Null

$succeeded = $false
try {
    $launcherProject = Join-Path $projectRoot 'src\PdfCompressor.Launcher\PdfCompressor.Launcher.csproj'
    & dotnet restore $launcherProject --configfile (Join-Path $projectRoot 'NuGet.Config') --no-cache -r $Runtime -p:NuGetAudit=true
    if ($LASTEXITCODE -ne 0) { throw 'Launcher restore failed.' }
    & dotnet publish $launcherProject -c Release -r $Runtime --self-contained true --no-restore -o $launcherOut `
        -p:Version=$productVersion -p:InformationalVersion=$buildId -p:IncludeSourceRevisionInInformationalVersion=false `
        -p:DebugSymbols=false -p:DebugType=embedded
    if ($LASTEXITCODE -ne 0) { throw 'Launcher publish failed.' }
    Copy-Item -LiteralPath (Join-Path $launcherOut 'PdfCompressor.App.exe') -Destination $stage
    $launcherSha256 = (Get-FileHash -LiteralPath (Join-Path $stage 'PdfCompressor.App.exe') -Algorithm SHA256).Hash

    Copy-Item -LiteralPath (Join-Path $projectRoot '_internal') -Destination $stage -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets\installed-compress.bat') -Destination (Join-Path $stage 'compress.bat')
    foreach ($relative in @('LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md')) { Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $stage }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'licenses') -Destination $stage -Recurse
    [IO.Directory]::CreateDirectory((Join-Path $stage 'runtime\pwsh')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $stage 'runtime\tools')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $stage 'runtime\ghostscript')) | Out-Null
    Copy-Item -Path (Join-Path ([IO.Path]::GetFullPath($PowerShellRoot)) '*') -Destination (Join-Path $stage 'runtime\pwsh') -Recurse

    $toolSources = [ordered]@{
        'qpdf.exe' = Find-RequiredTool $QpdfRoot 'qpdf.exe'
        'pdfinfo.exe' = Find-RequiredTool $PopplerRoot 'pdfinfo.exe'
        'pdfimages.exe' = Find-RequiredTool $PopplerRoot 'pdfimages.exe'
        'pdftoppm.exe' = Find-RequiredTool $PopplerRoot 'pdftoppm.exe'
        'pdfdetach.exe' = Find-RequiredTool $PopplerRoot 'pdfdetach.exe'
    }
    Copy-Item -Path (Join-Path ([IO.Path]::GetFullPath($GhostscriptRoot)) '*') -Destination (Join-Path $stage 'runtime\ghostscript') -Recurse
    foreach ($entry in $toolSources.GetEnumerator()) { Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $stage "runtime\tools\$($entry.Key)") }
    foreach ($sourceRoot in @($QpdfRoot, $PopplerRoot)) {
        foreach ($dll in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter '*.dll')) {
            $dest = Join-Path $stage "runtime\tools\$($dll.Name)"
            if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $dll.FullName -Destination $dest }
        }
    }

    foreach ($pdb in @(Get-ChildItem -LiteralPath $stage -Recurse -File -Filter '*.pdb')) { Remove-Item -LiteralPath $pdb.FullName -Force }
    $developerToolCache = Join-Path $stage '_internal\data\tool-paths.json'
    if (Test-Path -LiteralPath $developerToolCache) { Remove-Item -LiteralPath $developerToolCache -Force }
    $denied = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force | Where-Object {
        $_.Name -match '(^\.env$|^secrets?([._-]|$)|tool-paths\.json|\.pdb$|\.Tests\.ps1$|_spec\.ps1$)' -or $_.FullName -match '[\\/](tests?|obj|cache)[\\/]'
    })
    if ($denied) { throw "Denied payload files: $($denied.FullName -join ', ')" }

    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            path = [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            length = [long]$_.Length
        }
    })
    $treeDigest = Get-CanonicalDigest $files
    $toolVersions = [ordered]@{
        powershell = Get-ToolVersion (Join-Path $stage 'runtime\pwsh\pwsh.exe') @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')
        qpdf = Get-ToolVersion (Join-Path $stage 'runtime\tools\qpdf.exe') @('--version')
        poppler = Get-ToolVersion (Join-Path $stage 'runtime\tools\pdfinfo.exe') @('-v')
        ghostscript = Get-ToolVersion (Join-Path $stage 'runtime\ghostscript\bin\gswin64c.exe') @('-version')
    }
    $archive = Join-Path $candidate "pdf-compressor-$Runtime.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -CompressionLevel Optimal
    $archiveItem = Get-Item -LiteralPath $archive
    if ($archiveItem.Length -gt 262144000) { throw 'Payload exceeds the 250 MiB gate.' }

    $sourceBundleRoot = Join-Path $candidate 'corresponding-source'
    [IO.Directory]::CreateDirectory($sourceBundleRoot) | Out-Null
    $productSourceRoot = Join-Path $sourceBundleRoot 'product-source'
    foreach ($sourceEntry in $sourceInventory) {
        $relativeSourcePath = ([string]$sourceEntry.path).Replace('/', '\')
        $sourcePath = Join-Path $projectRoot $relativeSourcePath
        $destinationPath = Join-Path $productSourceRoot $relativeSourcePath
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
        if ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne [string]$sourceEntry.sha256) {
            throw "Product corresponding-source hash mismatch: $($sourceEntry.path)"
        }
    }
    $sourceDependencyNames = if ($Runtime -eq 'win-arm64') { @('qpdf', 'Poppler', 'Ghostscript') } else { @('Poppler', 'Ghostscript') }
    foreach ($dependency in @($runtimeDependencies | Where-Object { $_.name -in $sourceDependencyNames })) {
        $sourcePath = Get-DependencyArtifact $dependency $dependency.name
        Copy-Item -LiteralPath $sourcePath -Destination $sourceBundleRoot
    }
    Copy-Item -LiteralPath $dependencyLedger -Destination $sourceBundleRoot
    # AGPLv3 section 1 counts the scripts that control compilation and installation
    # as Corresponding Source, so every runtime ships its own build recipes. Shipping
    # them only for win-arm64 left the canonical win-x64 sidecar incomplete.
    $recipeRoot = Join-Path $sourceBundleRoot 'build-recipes'
    [IO.Directory]::CreateDirectory($recipeRoot) | Out-Null
    $buildRecipes = if ($Runtime -eq 'win-arm64') {
        @(
            'Build-QpdfArm64.ps1',
            'Build-PopplerArm64.ps1',
            'Build-GhostscriptArm64.ps1',
            'poppler-vcpkg.json',
            'Test-PopplerSourceSignature.ps1'
        )
    } else {
        @(
            'Build-Poppler.ps1',
            'poppler-vcpkg.json',
            'Test-PopplerSourceSignature.ps1'
        )
    }
    foreach ($recipe in $buildRecipes) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "dependencies\$recipe") -Destination $recipeRoot
    }
    $sourceBundle = Join-Path $candidate "pdf-compressor-corresponding-source-$Runtime.zip"
    Compress-Archive -Path (Join-Path $sourceBundleRoot '*') -DestinationPath $sourceBundle -CompressionLevel NoCompression

    Assert-ToolVersionsMatchLedger $toolVersions $runtimeDependencies

    $createdAt = [DateTimeOffset]::Now.ToString('o')
    $correspondingSource = [ordered]@{ archive = (Split-Path -Leaf $sourceBundle); sha256 = (Get-FileHash -LiteralPath $sourceBundle -Algorithm SHA256).Hash; length = [long](Get-Item -LiteralPath $sourceBundle).Length }
    $manifest = [ordered]@{
        schemaVersion = 3
        productId = 'pdf-compressor'
        productVersion = $productVersion
        releaseId = Get-SingleRuntimeReleaseId $buildId
        payloads = [ordered]@{
            $Runtime = [ordered]@{
                architecture = if ($Runtime -eq 'win-x64') { 'x64' } else { 'arm64' }
                archive = $archiveItem.Name
                sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
                length = [long]$archiveItem.Length
                treeDigest = $treeDigest
                toolVersions = $toolVersions
                files = $files
                build = [ordered]@{
                    buildId = $buildId
                    sourceDigest = $sourceDigest
                    dependencyDigest = $dependencyDigest
                    sdkVersion = $sdkVersion
                    createdAt = $createdAt
                    determinismMode = 'tree-digest-canonical'
                    correspondingSource = $correspondingSource
                }
            }
        }
    }
    $manifestPath = Join-Path $candidate 'payload-manifest.json'
    [IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
    $validationRoot = Join-Path $candidate 'validation-root'
    $validation = & (Join-Path $PSScriptRoot 'Test-Payload.ps1') -ManifestPath $manifestPath -Runtime $Runtime -ExtractTo $validationRoot -RunDiagnostics
    if (-not $validation.Valid) { throw 'Candidate validation did not return a valid result.' }
    $packageProfile = if ($Runtime -eq 'win-arm64') { 'arm64-only' } else { 'x64-only' }
    $profilePath = Join-Path $candidate "profiles\$packageProfile\root-entry.bat"
    $profileResult = & $entryRenderer -Profile $packageProfile -OutputPath $profilePath
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { throw "Package profile was not generated: $packageProfile" }
    Remove-Item -LiteralPath $validationRoot -Recurse -Force
    Remove-Item -LiteralPath $stage -Recurse -Force
    Remove-Item -LiteralPath $launcherOut -Recurse -Force
    $finalSourceDigest = Get-CanonicalDigest (Get-SourceInventory)
    if ($finalSourceDigest -ne $sourceDigest) {
        throw "Source inventory changed during candidate build: $sourceDigest -> $finalSourceDigest"
    }
    $receipt = [ordered]@{ schemaVersion = 1; status = 'candidate-validated'; buildId = $buildId; runtime = $Runtime; manifestSchemaVersion = 3; packageProfile = $packageProfile; profileEntrySha256 = $profileResult.Sha256; profileEntryLength = [long](Get-Item -LiteralPath $profilePath).Length; hostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant(); launcherSha256 = $launcherSha256; manifest = 'payload-manifest.json'; canonicalPayloadModified = $false; sourceDigest = $sourceDigest; dependencyDigest = $dependencyDigest; treeDigest = $treeDigest; archiveSha256 = $manifest.payloads.$Runtime.sha256; archiveLength = $manifest.payloads.$Runtime.length; correspondingSourceSha256 = $manifest.payloads.$Runtime.build.correspondingSource.sha256; createdAt = $createdAt }
    [IO.File]::WriteAllText((Join-Path $candidate 'build-receipt.json'), (($receipt | ConvertTo-Json -Depth 6) + "`n"), [Text.UTF8Encoding]::new($false))
    $succeeded = $true
    [pscustomobject]@{ Valid = $true; CandidateRoot = $candidate; BuildId = $buildId; ManifestPath = $manifestPath; Archive = $archive }
} finally {
    if (-not $succeeded -and -not $KeepFailedStage) {
        if (Test-Path -LiteralPath $candidate -PathType Container) { Remove-Item -LiteralPath $candidate -Recurse -Force }
    }
}
