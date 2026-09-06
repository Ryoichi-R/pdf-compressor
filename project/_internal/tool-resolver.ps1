# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Shared external-tool resolver. Single source of truth for the search
    order used by both compress.ps1 (runtime tool lookup) and
    setup-dependencies.ps1 (post-install verification).

    Search order:
      1. PATH exact .exe (Get-Command <name>.exe)
      2. Caller-supplied .exe -ExtraCandidates (e.g., tool-paths.json cache)
      3. Standard install roots:
           %ProgramFiles%
           %ProgramFiles(x86)%
           %LOCALAPPDATA%\Microsoft\WinGet\Packages
           %LOCALAPPDATA%\Microsoft\WinGet\Links

.OUTPUTS
    The first matching absolute path (string), or $null when no candidate exists.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Single source of truth for install-root search locations. Both runtime and
# setup paths must consult identical roots to avoid the WinGet\Links drift
# the original separate copies suffered from (P1-12).
$script:ToolSearchRoots = @(
    { $env:ProgramFiles },
    { ${env:ProgramFiles(x86)} },
    { if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages' } },
    { if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links' } }
)

function Get-ToolSearchRoots {
    <#
    .SYNOPSIS
        Evaluated, deduplicated list of existing install roots.
    #>
    $resolved = @()
    foreach ($block in $script:ToolSearchRoots) {
        $r = & $block
        if ($r -and (Test-Path -LiteralPath $r)) { $resolved += $r }
    }
    return $resolved
}

function Find-ToolExecutable {
    <#
    .PARAMETER Name
        Command stem (no .exe), e.g. 'gswin64c', 'qpdf', 'pdfinfo'.
    .PARAMETER ExtraCandidates
        Optional explicit paths to try after PATH but before the install-root
        recursive scan. Used by compress.ps1 to thread the tool-paths.json
        cache through.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyCollection()][AllowNull()][string[]]$ExtraCandidates = @()
    )

    # Installed distributions are hermetic: never consult PATH, developer
    # caches, or machine-wide installations.
    if ($env:PDF_COMPRESSOR_INSTALL_ROOT) {
        $root = [IO.Path]::GetFullPath($env:PDF_COMPRESSOR_INSTALL_ROOT).TrimEnd('\')
        $toolNames = @{
            qpdf      = 'qpdf.exe'
            pdfinfo   = 'pdfinfo.exe'
            pdfimages = 'pdfimages.exe'
            pdftoppm  = 'pdftoppm.exe'
            pdfsig    = 'pdfsig.exe'
            pdfdetach = 'pdfdetach.exe'
            gswin64c  = '..\ghostscript\bin\gswin64c.exe'
            gswin32c  = '..\ghostscript\bin\gswin32c.exe'
        }
        if (-not $toolNames.ContainsKey($Name)) { return $null }
        $candidate = Join-Path $root ('runtime\tools\' + $toolNames[$Name])
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
        return $null
    }

    # Prefer real executables. Command wrappers (.cmd/.bat) can corrupt
    # non-ASCII PDF paths before the native tool receives them.
    $cmd = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path -LiteralPath $cmd.Source)) {
        return $cmd.Source
    }

    if ($ExtraCandidates) {
        foreach ($c in $ExtraCandidates) {
            if ($c -and ([System.IO.Path]::GetExtension($c) -ieq '.exe') -and (Test-Path -LiteralPath $c)) {
                return (Resolve-Path -LiteralPath $c).Path
            }
        }
    }

    foreach ($root in Get-ToolSearchRoots) {
        $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}
