# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    pdf-compressor path-guard module. Enforces that all internal write targets
    stay within the installed pdf-compressor directory.

.DESCRIPTION
    Workspace policy implementation. Read access is unrestricted; internal
    write/temp/log paths must resolve under the tool root derived from this
    script's installed location.

.NOTES
    Used by: compress.ps1, analyze_pdf.ps1, invoke_*.ps1
    Tested by: tests/unit/path-guard.Tests.ps1
#>

Set-StrictMode -Version Latest

# Dedicated exception type so callers can `catch [PathGuardException] { exit 5 }`
# instead of fragile string matching against the message body (P1-13).
class PathGuardException : System.Exception {
    PathGuardException([string]$message) : base($message) {}
}

$script:ToolRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

function Get-PdfCompressorRoot {
    return $script:ToolRoot
}

function Assert-NoReparseAncestor {
    <#
    .SYNOPSIS
        Walk every existing ancestor of $TargetPath and throw if any of them
        is a reparse point (symlink / mount point / junction). This eliminates
        the TOCTOU window the old "follow reparse, then re-check" loop had
        (P1-7): an attacker could swap a directory for a symlink between the
        Get-Item call and the boundary comparison.

        Legitimate users with junctioned source directories should pre-resolve
        their paths via Resolve-Path -LiteralPath before passing them in.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetPath)

    $cursor = $TargetPath
    while ($true) {
        if (Test-Path -LiteralPath $cursor -ErrorAction SilentlyContinue) {
            try {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw [PathGuardException]::new(
                        "path-guard: reparse point in ancestor ($($item.FullName)). " +
                        "Pre-resolve with Resolve-Path -LiteralPath if this is intentional.")
                }
            } catch [PathGuardException] {
                throw
            } catch {
                throw [PathGuardException]::new("path-guard: cannot stat ancestor '$cursor': $($_.Exception.Message)")
            }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-WritePathInsideTool {
    <#
    .SYNOPSIS
        Throws (as PathGuardException) if $TargetPath does not resolve to a
        location strictly under the pdf-compressor directory.
    .DESCRIPTION
        Algorithm:
          1. Reject empty, UNC, \\?\ / \\.\, and relative paths outright.
          2. Walk every existing ancestor and reject if any is a reparse point
             (eliminates the TOCTOU window the old "follow then re-check"
             loop had — see Assert-NoReparseAncestor).
          3. Build the canonical full path via [System.IO.Path]::GetFullPath
             and case-insensitively compare against "$ToolRoot\".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        throw [PathGuardException]::new("path-guard: empty path.")
    }

    # UNC / long-path prefixes are not permitted for write targets.
    if ($TargetPath.StartsWith('\\?\') -or $TargetPath.StartsWith('\\.\')) {
        throw [PathGuardException]::new("path-guard: long-path prefix not permitted ($TargetPath).")
    }
    if ($TargetPath.StartsWith('\\')) {
        throw [PathGuardException]::new("path-guard: UNC path not permitted for write target ($TargetPath).")
    }

    # Reject relative paths outright — write targets must be fully rooted
    # so the boundary check does not depend on the current working directory.
    if (-not [System.IO.Path]::IsPathRooted($TargetPath)) {
        throw [PathGuardException]::new("path-guard: relative path not permitted ($TargetPath).")
    }

    # Structural TOCTOU defense: refuse if any existing ancestor is a reparse point.
    Assert-NoReparseAncestor -TargetPath $TargetPath

    $fullPath = [System.IO.Path]::GetFullPath($TargetPath)

    $toolRootNormalized = [System.IO.Path]::GetFullPath($script:ToolRoot)
    $toolRootSeparator = [System.IO.Path]::DirectorySeparatorChar
    if (-not $toolRootNormalized.EndsWith($toolRootSeparator)) {
        $toolRootNormalized = $toolRootNormalized + $toolRootSeparator
    }

    $lhs = $fullPath.ToLowerInvariant()
    $rhs = $toolRootNormalized.ToLowerInvariant()

    if (-not $lhs.StartsWith($rhs)) {
        throw [PathGuardException]::new("path-guard: write target '$fullPath' is outside '$toolRootNormalized'.")
    }

    return $fullPath
}

function Test-WritePathInsideTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetPath)
    try {
        Assert-WritePathInsideTool -TargetPath $TargetPath | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Assert-InputPathReadable {
    <#
    .SYNOPSIS
        Validate an input file or directory without applying write-path policy.

    .DESCRIPTION
        Input files may live outside the installed tool directory.  This guard
        therefore only checks that the path is absolute, exists, is not a
        device/UNC path, and has a supported PDF shape.  Reparse ancestors are
        rejected so the later enumeration does not silently cross a junction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [switch]$AllowDirectory
    )

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        throw [PathGuardException]::new('input-guard: input path is empty.')
    }
    if ($InputPath.StartsWith('\\?\') -or $InputPath.StartsWith('\\.\') -or $InputPath.StartsWith('\\')) {
        throw [PathGuardException]::new("input-guard: UNC/device/long path is not supported ($InputPath).")
    }
    if (-not [System.IO.Path]::IsPathRooted($InputPath)) {
        throw [PathGuardException]::new("input-guard: relative input path is not supported ($InputPath).")
    }

    $full = [System.IO.Path]::GetFullPath($InputPath)
    if (-not (Test-Path -LiteralPath $full)) {
        throw [PathGuardException]::new("input-guard: input path not found ($full).")
    }
    Assert-NoReparseAncestor -TargetPath $full
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        if (-not $AllowDirectory) {
            throw [PathGuardException]::new("input-guard: directory input is not allowed here ($full).")
        }
        return [pscustomobject]@{ path = $full; kind = 'directory'; item = $item }
    }
    if ($item.Extension -ine '.pdf') {
        throw [PathGuardException]::new("input-guard: input is not a PDF ($full).")
    }
    return [pscustomobject]@{ path = $full; kind = 'file'; item = $item }
}

function Test-InputPathReadable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [switch]$AllowDirectory
    )
    try {
        Assert-InputPathReadable -InputPath $InputPath -AllowDirectory:$AllowDirectory | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Assert-OutputPathLocal {
    <#
    .SYNOPSIS
        Throws (as PathGuardException) unless $TargetPath resolves to a local
        (drive-letter) path with no reparse-point ancestor.
    .DESCRIPTION
        Algorithm:
          1. Reject empty, UNC (\\server\share), \\?\ / \\.\, and relative paths.
          2. Require GetPathRoot to be a single drive letter (^[A-Za-z]:\\$).
          3. Require the drive root to exist.
          4. Reject if any existing ancestor is a reparse point — TOCTOU-safe
             alternative to the old "follow then re-check" loop (P1-7).
          5. Return the normalized full path.
    .NOTES
        Boundary for GUI -OutputRoot. _work\, compress.log.jsonl and other
        tool-internal writes continue to use Assert-WritePathInsideTool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        throw [PathGuardException]::new("path-guard: empty path.")
    }

    if ($TargetPath.StartsWith('\\?\') -or $TargetPath.StartsWith('\\.\')) {
        throw [PathGuardException]::new("path-guard: device/long-path prefix not permitted ($TargetPath).")
    }
    if ($TargetPath.StartsWith('\\')) {
        throw [PathGuardException]::new("path-guard: UNC path not permitted for output root ($TargetPath).")
    }
    if (-not [System.IO.Path]::IsPathRooted($TargetPath)) {
        throw [PathGuardException]::new("path-guard: relative path not permitted for output root ($TargetPath).")
    }

    $pathRoot = [System.IO.Path]::GetPathRoot($TargetPath)
    if ([string]::IsNullOrEmpty($pathRoot)) {
        throw [PathGuardException]::new("path-guard: cannot determine drive root ($TargetPath).")
    }
    if ($pathRoot -notmatch '^[A-Za-z]:\\$') {
        throw [PathGuardException]::new("path-guard: only single drive-letter roots are permitted ($pathRoot).")
    }
    if (-not (Test-Path -LiteralPath $pathRoot)) {
        throw [PathGuardException]::new("path-guard: drive root does not exist ($pathRoot).")
    }

    # Structural TOCTOU defense: refuse if any existing ancestor is a reparse point.
    Assert-NoReparseAncestor -TargetPath $TargetPath

    $fullPath = [System.IO.Path]::GetFullPath($TargetPath)

    # Re-check: full path must still resolve onto a local drive-letter root.
    $resolvedRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($resolvedRoot -notmatch '^[A-Za-z]:\\$') {
        throw [PathGuardException]::new("path-guard: resolved path is not on a local drive-letter root ($fullPath).")
    }
    if ($fullPath.StartsWith('\\')) {
        throw [PathGuardException]::new("path-guard: resolved path is UNC after normalization ($fullPath).")
    }

    return $fullPath
}

function Test-OutputPathLocal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetPath)
    try {
        Assert-OutputPathLocal -TargetPath $TargetPath | Out-Null
        return $true
    } catch {
        return $false
    }
}
