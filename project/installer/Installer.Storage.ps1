# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-InstallerCapacityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$NewPayloadBytes,
        [Parameter(Mandatory)][long]$CurrentManagedBytes,
        [Parameter(Mandatory)][long]$ExistingBackupBytes,
        [Parameter(Mandatory)][long]$AvailableBytes,
        [Parameter(Mandatory)][bool]$IsUpdate
    )
    foreach ($value in @($NewPayloadBytes, $CurrentManagedBytes, $ExistingBackupBytes, $AvailableBytes)) {
        if ($value -lt 0) { throw 'Capacity inputs must be non-negative.' }
    }
    $headroom = [long][math]::Max(256MB, [math]::Ceiling($NewPayloadBytes * 0.10))
    $requiredAdditional = if ($IsUpdate) {
        [long]($NewPayloadBytes + $CurrentManagedBytes + $headroom)
    } else {
        [long](2 * $NewPayloadBytes + $headroom)
    }
    $secondCopy = if ($IsUpdate) { $CurrentManagedBytes } else { $NewPayloadBytes }
    $predictedTotalPeak = [long]($CurrentManagedBytes + $ExistingBackupBytes + $NewPayloadBytes + $secondCopy + $headroom)
    [pscustomobject]@{
        newPayloadBytes = $NewPayloadBytes
        currentManagedBytes = $CurrentManagedBytes
        existingBackupBytes = $ExistingBackupBytes
        headroomBytes = $headroom
        requiredAdditionalBytes = $requiredAdditional
        predictedTotalPeakBytes = $predictedTotalPeak
        availableBytes = $AvailableBytes
        sufficient = $AvailableBytes -ge $requiredAdditional
    }
}

function Get-DirectoryFileBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [long]0 }
    $total = [long]0
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)) { $total += [long]$file.Length }
    return $total
}

function Get-InstallerBackupRetentionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [string]$PreferredKeepPath
    )
    $root = [IO.Path]::GetFullPath($BackupRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return [pscustomobject]@{ keep = $null; cleanupCandidates = @(); requiresApproval = $false }
    }
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $_.Name -like 'previous-*' } | Sort-Object Name -Descending)
    $keep = if ($PreferredKeepPath) { [IO.Path]::GetFullPath($PreferredKeepPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) } elseif ($candidates.Count -gt 0) { $candidates[0].FullName } else { $null }
    $cleanup = @($candidates | Where-Object { $_.FullName -ne $keep } | ForEach-Object {
        $full = [IO.Path]::GetFullPath($_.FullName).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsafe backup retention candidate: $full"
        }
        $full
    })
    [pscustomobject]@{ keep = $keep; cleanupCandidates = $cleanup; requiresApproval = $cleanup.Count -gt 0 }
}

function Remove-ApprovedInstallerBackups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string[]]$Candidates,
        [ValidateRange(1, 32)][int]$MaxCount = 8
    )
    $root = [IO.Path]::GetFullPath($BackupRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Backup root does not exist: $root"
    }
    $targets = @($Candidates | Sort-Object -Unique)
    if ($targets.Count -gt $MaxCount) {
        throw "Backup cleanup candidate count exceeds the limit: $($targets.Count) > $MaxCount"
    }

    # Validate the complete set before deleting any candidate. Only direct,
    # marker-bound previous-* children of the exact backup root are eligible.
    $validated = @(
        foreach ($candidate in $targets) {
            $full = [IO.Path]::GetFullPath($candidate).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $parent = [IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $leaf = Split-Path -Leaf $full
            if ($parent -ne $root -or $leaf -notmatch '^previous-\d{8}T\d{9}$') {
                throw "Unsafe backup cleanup target: $full"
            }
            if (-not (Test-Path -LiteralPath $full -PathType Container)) {
                throw "Backup cleanup target does not exist: $full"
            }
            $items = @(Get-Item -LiteralPath $full -Force) + @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop)
            if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
                throw "Backup cleanup target contains a reparse point: $full"
            }
            $markerPath = Join-Path $full '.pdf-compressor-install.json'
            if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
                throw "Backup cleanup target has no install marker: $full"
            }
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($marker.productId -ne 'pdf-compressor') {
                throw "Backup cleanup target marker is invalid: $full"
            }
            $full
        }
    )
    foreach ($target in $validated) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    }
    return @($validated)
}
