# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    pdf-compressor dependency installer. winget primary; manual fallback URLs
    on winget failure; tool-paths.json self-healing cache.

.EXAMPLE
    pwsh _internal/setup-dependencies.ps1
#>

[CmdletBinding()]
param(
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = $PSScriptRoot
$dataDir = Join-Path $scriptDir 'data'
$toolPathsFile = Join-Path $dataDir 'tool-paths.json'

. (Join-Path $scriptDir 'path-guard.ps1')
. (Join-Path $scriptDir 'tool-resolver.ps1')

$packages = @(
    @{ name = 'Ghostscript'; cmd = 'gswin64c'; id = $null;                       manual = 'https://www.ghostscript.com/releases/gsdnld.html' }
    @{ name = 'qpdf';        cmd = 'qpdf';     id = 'QPDF.QPDF';                 manual = 'https://github.com/qpdf/qpdf/releases' }
    @{ name = 'Poppler';     cmd = 'pdfinfo';  id = 'oschwartz10612.Poppler';    manual = 'https://github.com/oschwartz10612/poppler-windows/releases' }
)

function Test-CommandAvailable {
    param([string]$Cmd)
    return [bool](Get-Command $Cmd -ErrorAction SilentlyContinue)
}

function Invoke-WingetInstall {
    param(
        [string]$PackageId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ManualUrl
    )

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        Write-Host "[INFO] $Name is not currently available from this winget source. Install it manually: $ManualUrl" -ForegroundColor Yellow
        return [pscustomobject]@{ ok = $false; reason = 'manual-required' }
    }

    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        return [pscustomobject]@{ ok = $false; reason = 'winget-missing' }
    }

    Write-Host "Installing $PackageId via winget..."
    $argsList = @('install', '--exact', '--id', $PackageId, '--accept-source-agreements', '--accept-package-agreements', '--silent')
    & winget @argsList 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) {
        return [pscustomobject]@{ ok = $true; reason = $null }
    }
    # Try --scope user fallback if machine scope was implicit.
    & winget install --exact --id $PackageId --scope user --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) {
        return [pscustomobject]@{ ok = $true; reason = $null }
    }
    return [pscustomobject]@{ ok = $false; reason = "winget-rc-$LASTEXITCODE" }
}

# Find-InstalledExe used to duplicate the search-root logic. It now delegates
# to the shared Find-ToolExecutable (tool-resolver.ps1) so the two callers
# (this script and compress.ps1) can never drift on which roots get scanned.
function Find-InstalledExe {
    param([Parameter(Mandatory)][string]$Cmd)
    return Find-ToolExecutable -Name $Cmd
}

# ---- Main ----
$missing = @()
foreach ($pkg in $packages) {
    if (-not (Test-CommandAvailable -Cmd $pkg.cmd)) { $missing += $pkg }
}

if ($missing.Count -eq 0 -and -not $SkipInstall) {
    Write-Host "[OK] All dependencies already available on PATH."
}

if ($missing.Count -gt 0 -and -not $SkipInstall) {
    foreach ($pkg in $missing) {
        $r = Invoke-WingetInstall -PackageId $pkg.id -Name $pkg.name -ManualUrl $pkg.manual
        if (-not $r.ok) {
            if ($r.reason -eq 'manual-required') {
                Write-Host ("[INFO] {0} requires manual installation before setup can complete." -f $pkg.name) -ForegroundColor Yellow
            } else {
                Write-Host ("[ERROR] {0} install failed ({1}). Manual download: {2}" -f $pkg.name, $r.reason, $pkg.manual) -ForegroundColor Red
            }
        }
    }
    # PATH may not be refreshed in current session; rely on Find-InstalledExe.
}

# Resolve final paths and persist.
$resolved = [ordered]@{}
$stillMissing = @()
foreach ($pkg in $packages) {
    $p = Find-InstalledExe -Cmd $pkg.cmd
    if ($p) {
        $resolved[$pkg.cmd] = $p
    } else {
        $stillMissing += $pkg.cmd
    }
}

if ($stillMissing.Count -gt 0) {
    Write-Host "[ERROR] Could not resolve: $($stillMissing -join ', ')" -ForegroundColor Red
    foreach ($pkg in $packages | Where-Object { $stillMissing -contains $_.cmd }) {
        Write-Host ("  - {0}: {1}" -f $pkg.name, $pkg.manual)
    }
    exit 2
}

# Map command name -> friendly key used by compress.ps1 cache.
$friendly = [ordered]@{
    ghostscript = $resolved['gswin64c']
    qpdf        = $resolved['qpdf']
    pdfinfo     = $resolved['pdfinfo']
    pdfimages   = (Find-InstalledExe -Cmd 'pdfimages')
}

if (-not $friendly.pdfimages) {
    Write-Host "[ERROR] Could not resolve: pdfimages" -ForegroundColor Red
    Write-Host "  - Poppler: https://github.com/oschwartz10612/poppler-windows/releases"
    exit 2
}

Assert-WritePathInsideTool -TargetPath $toolPathsFile | Out-Null
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
$friendly | ConvertTo-Json | Set-Content -LiteralPath $toolPathsFile -Encoding UTF8

Write-Host "[OK] tool-paths.json written:"
$friendly.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-12} = {1}" -f $_.Key, $_.Value) }
exit 0
