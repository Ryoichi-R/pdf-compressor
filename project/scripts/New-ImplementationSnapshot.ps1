[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [string[]]$BackupPath = @(),
    [string[]]$WorkspaceBackupPath = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..')).TrimEnd('\')

function Test-SecretFilePath([string]$FilePath) {
    $leaf = Split-Path $FilePath -Leaf
    foreach ($pattern in @('^\.env$', '^\.env\.', '^secrets\.', '\.key$', '\.pem$', '\.pfx$', '\.p12$', '^credentials\.')) {
        if ($leaf -match $pattern) { return $true }
    }
    return $false
}

if (Test-SecretFilePath -FilePath $repositoryRoot) { throw 'SNAPSHOT_SECRET_PATH_REJECTED' }
$outputFull = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
if (Test-SecretFilePath -FilePath $outputFull) { throw 'SNAPSHOT_SECRET_PATH_REJECTED' }
if ($outputFull -eq $repositoryRoot -or
    -not $outputFull.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SNAPSHOT_OUTPUT_OUTSIDE_REPOSITORY'
}
if (Test-Path -LiteralPath $outputFull) { throw 'SNAPSHOT_OUTPUT_ALREADY_EXISTS' }

$outputParent = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    [IO.Directory]::CreateDirectory($outputParent) | Out-Null
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

$backupSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($relative in $BackupPath) {
    if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) {
        throw "BACKUP_PATH_MUST_BE_PROJECT_RELATIVE: $relative"
    }
    $source = [IO.Path]::GetFullPath((Join-Path $projectRoot $relative))
    if (Test-SecretFilePath -FilePath $source) { throw 'SNAPSHOT_SECRET_PATH_REJECTED' }
    if (-not $source.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "BACKUP_PATH_OUTSIDE_PROJECT: $relative"
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "BACKUP_FILE_MISSING: $relative" }
    $null = $backupSet.Add([IO.Path]::GetRelativePath($projectRoot, $source).Replace('\', '/'))
}

$files = [Collections.Generic.List[object]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $projectRoot -File -Recurse -Force | Sort-Object FullName)) {
    if (Test-SecretFilePath -FilePath $file.FullName) { throw 'SNAPSHOT_SECRET_PATH_REJECTED' }
    $relative = [IO.Path]::GetRelativePath($projectRoot, $file.FullName).Replace('\', '/')
    $entry = [ordered]@{
        path = $relative
        length = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        byteBackup = $backupSet.Contains($relative)
    }
    if ($entry.byteBackup) {
        $destination = Join-Path $outputFull ('files\' + $relative.Replace('/', '\'))
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
    $files.Add($entry)
}

$workspaceBackups = [Collections.Generic.List[object]]::new()
foreach ($relative in $WorkspaceBackupPath) {
    if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) {
        throw "WORKSPACE_BACKUP_PATH_MUST_BE_RELATIVE: $relative"
    }
    $source = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $relative))
    if (Test-SecretFilePath -FilePath $source) { throw 'SNAPSHOT_SECRET_PATH_REJECTED' }
    if (-not $source.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "WORKSPACE_BACKUP_PATH_OUTSIDE_REPOSITORY: $relative"
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "WORKSPACE_BACKUP_FILE_MISSING: $relative" }
    $normalized = [IO.Path]::GetRelativePath($repositoryRoot, $source).Replace('\', '/')
    $destination = Join-Path $outputFull ('workspace-files\' + $normalized.Replace('/', '\'))
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
    $info = Get-Item -LiteralPath $source
    $workspaceBackups.Add([ordered]@{
        path = $normalized
        length = [int64]$info.Length
        sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

$payloadManifest = Join-Path $projectRoot 'installer\payload\payload-manifest.json'
$payloadBaseline = $null
if (Test-Path -LiteralPath $payloadManifest -PathType Leaf) {
    $manifest = Get-Content -LiteralPath $payloadManifest -Raw | ConvertFrom-Json
    $payloadBaseline = [ordered]@{
        manifestPath = 'installer/payload/payload-manifest.json'
        manifestSha256 = (Get-FileHash -LiteralPath $payloadManifest -Algorithm SHA256).Hash.ToLowerInvariant()
        runtimes = @($manifest.payloads.PSObject.Properties | ForEach-Object {
            $archivePath = Join-Path (Split-Path -Parent $payloadManifest) $_.Value.archive
            [ordered]@{
                runtime = $_.Name
                archivePath = ('installer/payload/' + $_.Value.archive)
                archiveLength = [int64](Get-Item -LiteralPath $archivePath).Length
                archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
                fileCount = @($_.Value.files).Count
            }
        })
    }
}

$manifestObject = [ordered]@{
    schemaVersion = 1
    snapshotType = 'pdf-compressor-implementation-baseline'
    createdAt = [DateTimeOffset]::Now.ToString('o')
    workspacePolicy = 'standalone-repository-filesystem-only'
    projectRoot = 'project'
    backupRule = 'Only explicitly listed editable files are copied; large immutable artifacts are hash inventory only.'
    files = @($files)
    workspaceBackups = @($workspaceBackups)
    payloadBaseline = $payloadBaseline
}
$manifestPath = Join-Path $outputFull 'snapshot-manifest.json'
if (Test-SecretFilePath -FilePath $manifestPath) { throw 'SNAPSHOT_SECRET_PATH_REJECTED' }
[IO.File]::WriteAllText($manifestPath, (($manifestObject | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Status = 'SNAPSHOT_CREATED'; ManifestPath = $manifestPath; FileCount = $files.Count; BackupCount = $backupSet.Count + $workspaceBackups.Count }
