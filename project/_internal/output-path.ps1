# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Item-scoped output path resolution for pdf-compressor.

.DESCRIPTION
    Output derivation is deliberately independent from the compression
    orchestrator.  The resolver receives its root and collision map explicitly
    so multiple manifest items cannot share mutable script state.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OutputHash12 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return (-join ($hash | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }))
}

function ConvertTo-OutputSafeSegment {
    param([Parameter(Mandatory)][string]$Segment)
    $reserved = @('CON','PRN','AUX','NUL') + (1..9 | ForEach-Object { "COM$_" }) + (1..9 | ForEach-Object { "LPT$_" })
    if ([string]::IsNullOrWhiteSpace($Segment) -or $Segment -in @('.', '..')) { return '_' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Segment.ToCharArray()) {
        if ([char[]]'<>:"/\|?*' -contains $ch -or [int]$ch -lt 32) { [void]$sb.Append('_') }
        else { [void]$sb.Append($ch) }
    }
    $safe = $sb.ToString()
    while ($safe.EndsWith(' ') -or $safe.EndsWith('.')) { $safe = $safe.Substring(0, $safe.Length - 1) }
    if ([string]::IsNullOrEmpty($safe)) { $safe = '_' }
    $stem = if ($safe.Contains('.')) { $safe.Substring(0, $safe.IndexOf('.')) } else { $safe }
    if ($reserved -contains $stem.ToUpperInvariant()) { $safe += '_' }
    return $safe
}

function Get-OutputOriginId {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $full = $File.FullName
    if ($full.StartsWith('\\')) {
        $parts = $full.Substring(2).Split('\')
        if ($parts.Count -lt 2) { throw "output-path: invalid UNC path '$full'." }
        $share = ('\\' + $parts[0] + '\' + $parts[1]).ToLowerInvariant()
        return "unc-$(Get-OutputHash12 -Text $share)"
    }
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) { throw "output-path: cannot determine drive root '$full'." }
    return "drive-$($root.Substring(0,1).ToLowerInvariant())-$(Get-OutputHash12 -Text $root.ToLowerInvariant())"
}

function Get-OutputRelativeDirectory {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter()][string]$SourceRoot
    )
    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($File.DirectoryName)) { return '' }
    $root = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $dir = [System.IO.Path]::GetFullPath($File.DirectoryName).TrimEnd('\')
    if ($dir.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    if ($dir.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $dir.Substring($root.Length + 1)
    }
    return ''
}

function New-OutputPathContext {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][bool]$UseOutsideOutputRoot
    )
    return [pscustomobject]@{
        source_root = [System.IO.Path]::GetFullPath($SourceRoot)
        output_root = [System.IO.Path]::GetFullPath($OutputRoot)
        use_outside_output_root = $UseOutsideOutputRoot
        seen_map = @{}
    }
}

function Resolve-OutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Pdf,
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][ref]$SeenMap
    )
    $stem = ConvertTo-OutputSafeSegment -Segment ([System.IO.Path]::GetFileNameWithoutExtension($Pdf.Name))
    $segments = @()
    if ([bool]$Context.use_outside_output_root) {
        $relative = Get-OutputRelativeDirectory -File $Pdf -SourceRoot ([string]$Context.source_root)
        if ($relative) {
            $segments += @($relative.Split([char[]]'\/',[System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
                ConvertTo-OutputSafeSegment -Segment $_
            })
        }
    } else {
        $segments += Get-OutputOriginId -File $Pdf
        $parent = $Pdf.DirectoryName
        if ($parent) {
            $root = [System.IO.Path]::GetPathRoot($parent)
            $relative = if ($root -and $parent.Length -gt $root.Length) { $parent.Substring($root.Length) } else { '' }
            if ($relative) {
                $segments += @($relative.Split([char[]]'\/',[System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
                    ConvertTo-OutputSafeSegment -Segment $_
                })
            }
        }
    }

    $leaf = "$stem.compressed.pdf"
    $relativePath = ($segments + $leaf) -join '\'
    $key = $relativePath.ToLowerInvariant()
    $identity = $Pdf.FullName.ToLowerInvariant()
    $map = $SeenMap.Value
    if ($null -eq $map) { $map = @{}; $SeenMap.Value = $map }
    if ($map.ContainsKey($key) -and $map[$key] -ne $identity) {
        $leaf = "$stem~$(Get-OutputHash12 -Text $identity).compressed.pdf"
        $relativePath = ($segments + $leaf) -join '\'
        $key = $relativePath.ToLowerInvariant()
    }
    if (-not $map.ContainsKey($key)) { $map[$key] = $identity }

    $target = [System.IO.Path]::GetFullPath((Join-Path ([string]$Context.output_root) $relativePath))
    if ([bool]$Context.use_outside_output_root) {
        Assert-OutputPathLocal -TargetPath $target | Out-Null
    } else {
        Assert-WritePathInsideTool -TargetPath $target | Out-Null
    }
    return $target
}
