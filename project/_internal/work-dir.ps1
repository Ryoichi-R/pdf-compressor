# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Work-directory lifecycle helpers.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-WorkDirOwnerAliveCore {
    param([Parameter(Mandatory)][string]$DirName)
    if ($DirName -notmatch '^(?<pid>\d+)-') { return $false }
    return [bool](Get-Process -Id ([int]$Matches.pid) -ErrorAction SilentlyContinue)
}

function Invoke-WorkDirCleanupCore {
    param([Parameter(Mandatory)][string]$WorkRoot,[int]$TtlHours = 24)
    if (-not (Test-Path -LiteralPath $WorkRoot)) { return }
    $cutoff = (Get-Date).AddHours(-1 * [math]::Abs($TtlHours))
    Get-ChildItem -LiteralPath $WorkRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            if (Test-WorkDirOwnerAliveCore -DirName $_.Name) { return }
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
}

function New-WorkSubdirectory {
    param([Parameter(Mandatory)][string]$WorkRoot)
    $path = Join-Path $WorkRoot ("$PID-" + [Guid]::NewGuid().ToString('N'))
    Assert-WritePathInsideTool -TargetPath $path | Out-Null
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
