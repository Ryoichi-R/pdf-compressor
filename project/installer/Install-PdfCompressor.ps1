# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Runtime,
    [switch]$NoOpen,
    [switch]$AllowRuntimeSwitch,
    [switch]$ApproveBackupRetentionCleanup,
    # Test-only injection. The shipped root BAT never forwards this switch.
    [Parameter(DontShow)][int]$TestFailAfterFiles = 0,
    [Parameter(DontShow)][long]$TestAvailableBytes = -1
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProductId = 'pdf-compressor'
$FolderName = 'PDF Compressor'
$MarkerName = '.pdf-compressor-install.json'
$ExitInvalid = 2
$ExitPayload = 3
$ExitCancelled = 4
$ExitBusy = 8
$ExitRollbackFailed = 9
$ExitCapacity = 10
$ExitRuntimeSwitchRequired = 12

. (Join-Path $PSScriptRoot 'Installer.Storage.ps1')

function Write-InstallerError([string]$Message) {
    [Console]::Error.WriteLine("[ERROR] $Message")
}

function Get-InstallPathHash([string]$Path) {
    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
        ) -replace '-', '').Substring(0, 24)
    } finally { $sha.Dispose() }
}

function Get-ManagedPathKey([string]$Path) {
    return $Path.Replace('\', '/').ToLowerInvariant()
}

function Assert-LocalPlainDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Folder does not exist: $full" }
    if ($full.StartsWith('\\') -or $full.StartsWith('\\?\') -or $full.StartsWith('\\.\')) {
        throw 'UNC and device paths are not supported.'
    }
    $current = Get-Item -LiteralPath $full -Force
    while ($current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not supported: $($current.FullName)"
        }
        $current = $current.Parent
    }
    return $full.TrimEnd('\')
}

function Select-InstallParent {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'PDF Compressor のインストール先となる親フォルダーを選択してください。'
    $dialog.ShowNewFolderButton = $true
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $null }
        return $dialog.SelectedPath
    } finally { $dialog.Dispose() }
}

if ($Runtime -notin @('win-x64', 'win-arm64')) {
    Write-InstallerError "Unknown runtime token: $Runtime"
    exit $ExitInvalid
}

$parent = $env:PDF_COMPRESSOR_INSTALL_PARENT
if ([string]::IsNullOrWhiteSpace($parent)) { $parent = Select-InstallParent }
if ([string]::IsNullOrWhiteSpace($parent)) { exit $ExitCancelled }
try { $parent = Assert-LocalPlainDirectory $parent } catch { Write-InstallerError $_.Exception.Message; exit $ExitInvalid }
$installRoot = Join-Path $parent $FolderName
$installHash = Get-InstallPathHash $installRoot
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$stateRoot = Join-Path $localAppData "$ProductId\runtime-state\$installHash"
$backupRoot = Join-Path $localAppData "$ProductId\backups\$installHash"
[IO.Directory]::CreateDirectory($stateRoot) | Out-Null
[IO.Directory]::CreateDirectory($backupRoot) | Out-Null

$gate = New-Object Threading.Mutex($false, "Local\PdfCompressor-Update-$installHash")
$ownsGate = $false
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("pdf-compressor-install-" + [Guid]::NewGuid().ToString('N'))
$backup = $null
$oldMarker = $null
$newFiles = @()
$missingOldPathSet = @{}
try {
    $ownsGate = $gate.WaitOne(0)
    if (-not $ownsGate) { Write-InstallerError 'Another update or application launch is active.'; exit $ExitBusy }
    $leases = @(Get-ChildItem -LiteralPath $stateRoot -Filter 'lease-*.lock' -File -ErrorAction SilentlyContinue)
    foreach ($lease in $leases) {
        try {
            $probe = [IO.File]::Open($lease.FullName, 'Open', 'ReadWrite', 'None')
            $probe.Dispose()
            Remove-Item -LiteralPath $lease.FullName -Force
        } catch [IO.IOException] {
            Write-InstallerError 'PDF Compressor is currently running. Close it before updating.'
            exit $ExitBusy
        }
    }

    [IO.Directory]::CreateDirectory($staging) | Out-Null
    $manifestPath = Join-Path $PSScriptRoot 'payload\payload-manifest.json'
    try {
        & (Join-Path $PSScriptRoot 'Test-Payload.ps1') -ManifestPath $manifestPath -Runtime $Runtime -ExtractTo $staging | Out-Null
    } catch {
        Write-InstallerError "Payload verification failed: $($_.Exception.Message)"
        exit $ExitPayload
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $newFiles = @($manifest.payloads.$Runtime.files)

    $isUpdate = Test-Path -LiteralPath $installRoot -PathType Container
    $currentBytes = [long]0
    if ($isUpdate) {
        $preflightMarkerPath = Join-Path $installRoot $MarkerName
        if (-not (Test-Path -LiteralPath $preflightMarkerPath -PathType Leaf)) {
            Write-InstallerError "Refusing to update an unowned folder: $installRoot"
            exit $ExitInvalid
        }
        $preflightMarker = Get-Content -LiteralPath $preflightMarkerPath -Raw | ConvertFrom-Json
        if ($preflightMarker.productId -ne $ProductId) { throw 'Install marker product id mismatch.' }
        if ($preflightMarker.PSObject.Properties['runtime'] -and
            $preflightMarker.runtime -ne $Runtime -and -not $AllowRuntimeSwitch) {
            Write-InstallerError ("Installed runtime is {0}; requested runtime is {1}. Re-run with explicit runtime-switch approval." -f $preflightMarker.runtime, $Runtime)
            exit $ExitRuntimeSwitchRequired
        }
        foreach ($file in @($preflightMarker.managedFiles)) {
            $managedPath = Join-Path $installRoot $file.path
            $managedStream = $null
            try {
                # Capacity accounting is advisory for existing bytes. A missing
                # managed file is damaged state to repair, not a fatal preflight
                # error. Open once so a Test-Path/Get-Item race is impossible.
                $managedStream = [IO.File]::Open($managedPath, 'Open', 'Read', 'ReadWrite')
                $currentBytes += [long]$managedStream.Length
            } catch [IO.FileNotFoundException] {
                continue
            } catch [IO.DirectoryNotFoundException] {
                continue
            } finally {
                if ($managedStream) { $managedStream.Dispose() }
            }
        }
    }
    $newBytes = [long](($newFiles | Measure-Object -Property length -Sum).Sum)
    $existingBackupBytes = Get-DirectoryFileBytes -Path $backupRoot
    $availableBytes = if ($TestAvailableBytes -ge 0) { $TestAvailableBytes } else { [long]([IO.DriveInfo]::new([IO.Path]::GetPathRoot($installRoot))).AvailableFreeSpace }
    $capacity = Get-InstallerCapacityPlan -NewPayloadBytes $newBytes -CurrentManagedBytes $currentBytes -ExistingBackupBytes $existingBackupBytes -AvailableBytes $availableBytes -IsUpdate:$isUpdate
    Write-Host ("容量診断: Enew={0} Ecurrent={1} Bexisting={2} H={3} requiredAdditional={4} available={5} predictedTotalPeak={6}" -f $capacity.newPayloadBytes,$capacity.currentManagedBytes,$capacity.existingBackupBytes,$capacity.headroomBytes,$capacity.requiredAdditionalBytes,$capacity.availableBytes,$capacity.predictedTotalPeakBytes)
    if (-not $capacity.sufficient) {
        Write-InstallerError ("Insufficient free space. Required additional bytes: {0}; available bytes: {1}." -f $capacity.requiredAdditionalBytes, $capacity.availableBytes)
        exit $ExitCapacity
    }

    if (Test-Path -LiteralPath $installRoot) {
        $markerPath = Join-Path $installRoot $MarkerName
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            Write-InstallerError "Refusing to update an unowned folder: $installRoot"
            exit $ExitInvalid
        }
        $oldMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($oldMarker.productId -ne $ProductId) { throw 'Install marker product id mismatch.' }
        if ($oldMarker.PSObject.Properties['runtime'] -and
            $oldMarker.runtime -ne $Runtime -and -not $AllowRuntimeSwitch) {
            Write-InstallerError ("Installed runtime is {0}; requested runtime is {1}. Re-run with explicit runtime-switch approval." -f $oldMarker.runtime, $Runtime)
            exit $ExitRuntimeSwitchRequired
        }
        $backup = Join-Path $backupRoot ('previous-' + (Get-Date -Format 'yyyyMMddTHHmmssfff'))
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        foreach ($file in @($oldMarker.managedFiles)) {
            $source = Join-Path $installRoot $file.path
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                $missingOldPathSet[(Get-ManagedPathKey $file.path)] = $true
                continue
            }
            $sourceStream = $null
            $destStream = $null
            $sha256 = $null
            try {
                # Open once, then hash and copy through the same handle. This
                # avoids a Test-Path/Get-FileHash race if a damaged install is
                # concurrently cleaned up by another local process.
                $sourceStream = [IO.File]::Open($source, 'Open', 'Read', 'Read')
                $sha256 = [Security.Cryptography.SHA256]::Create()
                $actualHash = ([BitConverter]::ToString($sha256.ComputeHash($sourceStream)) -replace '-', '')
                if ($actualHash -ne $file.sha256) {
                    throw "Managed file was modified locally: $($file.path)"
                }
                $dest = Join-Path $backup $file.path
                [IO.Directory]::CreateDirectory((Split-Path $dest)) | Out-Null
                $sourceStream.Position = 0
                $destStream = [IO.File]::Open($dest, 'CreateNew', 'Write', 'None')
                $sourceStream.CopyTo($destStream)
            } catch [IO.FileNotFoundException] {
                $missingOldPathSet[(Get-ManagedPathKey $file.path)] = $true
            } catch [IO.DirectoryNotFoundException] {
                $missingOldPathSet[(Get-ManagedPathKey $file.path)] = $true
            } finally {
                if ($destStream) { $destStream.Dispose() }
                if ($sha256) { $sha256.Dispose() }
                if ($sourceStream) { $sourceStream.Dispose() }
            }
        }
        Copy-Item -LiteralPath $markerPath -Destination (Join-Path $backup $MarkerName)
    } else {
        [IO.Directory]::CreateDirectory($installRoot) | Out-Null
    }

    $probePath = Join-Path $installRoot ('.write-probe-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($probePath, 'ok')
    Remove-Item -LiteralPath $probePath -Force

    $copiedCount = 0
    foreach ($file in $newFiles) {
        $source = Join-Path $staging $file.path
        $dest = Join-Path $installRoot $file.path
        [IO.Directory]::CreateDirectory((Split-Path $dest)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $dest -Force
        $copiedCount++
        if ($TestFailAfterFiles -gt 0 -and $copiedCount -ge $TestFailAfterFiles) {
            throw "Test-only injected failure after $copiedCount managed files."
        }
    }
    $newPathSet = @{}
    foreach ($file in $newFiles) { $newPathSet[(Get-ManagedPathKey $file.path)] = $true }
    if ($oldMarker) {
        foreach ($old in @($oldMarker.managedFiles)) {
            if (-not $newPathSet.ContainsKey((Get-ManagedPathKey $old.path))) {
                $obsolete = Join-Path $installRoot $old.path
                if (Test-Path -LiteralPath $obsolete -PathType Leaf) { Remove-Item -LiteralPath $obsolete -Force }
            }
        }
    }
    $marker = [ordered]@{
        schemaVersion = 1
        productId = $ProductId
        runtime = $Runtime
        installedAt = [DateTimeOffset]::Now.ToString('o')
        payloadSha256 = $manifest.payloads.$Runtime.sha256
        buildId = if ($manifest.schemaVersion -eq 3) { $manifest.payloads.$Runtime.build.buildId } elseif ($manifest.schemaVersion -eq 2) { $manifest.buildId } else { $null }
        managedFiles = $newFiles
    }
    $marker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $installRoot $MarkerName) -Encoding UTF8
    foreach ($file in $newFiles) {
        $dest = Join-Path $installRoot $file.path
        if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $file.sha256) {
            throw "Post-install verification failed: $($file.path)"
        }
    }
    $retention = Get-InstallerBackupRetentionPlan -BackupRoot $backupRoot -PreferredKeepPath $backup
    if ($retention.requiresApproval) {
        if ($ApproveBackupRetentionCleanup) {
            $removed = @(Remove-ApprovedInstallerBackups -BackupRoot $backupRoot -Candidates $retention.cleanupCandidates)
            Write-Host ("backup retention cleanup completed: {0} older backup(s); retained path: {1}" -f $removed.Count, $retention.keep)
        } else {
            Write-Host ("backup retention cleanup pending approval: {0} older backup(s); retained path: {1}" -f $retention.cleanupCandidates.Count, $retention.keep)
        }
    }
    Write-Host "インストール／更新が完了しました: $installRoot"
    Write-Host '起動ファイル: PdfCompressor.App.exe'
    if (-not $NoOpen) {
        Start-Process explorer.exe -ArgumentList @("/select,`"$(Join-Path $installRoot 'PdfCompressor.App.exe')`"")
    }
    exit 0
} catch {
    Write-InstallerError "Installation failed: $($_.Exception.Message)"
    if ($backup -and (Test-Path -LiteralPath (Join-Path $backup $MarkerName))) {
        try {
            $backupMarker = Get-Content -LiteralPath (Join-Path $backup $MarkerName) -Raw | ConvertFrom-Json
            $oldPathSet = @{}
            foreach ($file in @($backupMarker.managedFiles)) { $oldPathSet[(Get-ManagedPathKey $file.path)] = $true }
            foreach ($file in @($newFiles)) {
                $pathKey = Get-ManagedPathKey $file.path
                if (-not $oldPathSet.ContainsKey($pathKey) -or $missingOldPathSet.ContainsKey($pathKey)) {
                    $introduced = Join-Path $installRoot $file.path
                    if (Test-Path -LiteralPath $introduced -PathType Leaf) {
                        Remove-Item -LiteralPath $introduced -Force
                    }
                }
            }
            foreach ($file in @($backupMarker.managedFiles)) {
                $source = Join-Path $backup $file.path
                if (Test-Path -LiteralPath $source -PathType Leaf) {
                    $dest = Join-Path $installRoot $file.path
                    [IO.Directory]::CreateDirectory((Split-Path $dest)) | Out-Null
                    Copy-Item -LiteralPath $source -Destination $dest -Force
                }
            }
            Copy-Item -LiteralPath (Join-Path $backup $MarkerName) -Destination (Join-Path $installRoot $MarkerName) -Force
        } catch {
            Write-InstallerError "Rollback also failed. Backup retained at: $backup"
            exit $ExitRollbackFailed
        }
    }
    exit 1
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    if ($ownsGate) { try { $gate.ReleaseMutex() } catch [ApplicationException] {} }
    $gate.Dispose()
}
