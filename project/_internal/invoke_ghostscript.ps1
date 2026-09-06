# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Ghostscript wrapper. Explicit distiller parameters (no /ebook preset).
    All arguments passed via PowerShell array form — no string interpolation.

.OUTPUTS
    PSCustomObject: success (bool), exitCode (int), tool (string),
    stderr (string), command (string[]).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Ghostscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GhostscriptExe,
        [Parameter(Mandatory)][string]$InputPdf,
        [Parameter(Mandatory)][string]$OutputPdf,
        [Parameter(Mandatory)][int]$ColorDpi,
        [Parameter(Mandatory)][int]$GrayDpi,
        # DPI whitelist sourced from strategies.json (SSoT). Caller (compress.ps1)
        # passes $Strategies.allowed_dpi so this wrapper has no embedded values.
        [Parameter(Mandatory)][int[]]$AllowedDpi,
        [switch]$DownsampleMono
    )

    if ($ColorDpi -lt 72 -or $ColorDpi -gt 600) { throw "invoke_ghostscript: color_dpi out of range: $ColorDpi" }
    if ($GrayDpi  -lt 72 -or $GrayDpi  -gt 600) { throw "invoke_ghostscript: gray_dpi out of range: $GrayDpi" }
    if ($AllowedDpi -notcontains $ColorDpi) { throw "invoke_ghostscript: color_dpi not whitelisted: $ColorDpi" }
    if ($AllowedDpi -notcontains $GrayDpi) { throw "invoke_ghostscript: gray_dpi not whitelisted: $GrayDpi" }

    if (-not (Test-Path -LiteralPath $GhostscriptExe)) {
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'ghostscript'; stderr = "ghostscript missing: $GhostscriptExe"; command = @() }
    }
    if (-not (Test-Path -LiteralPath $InputPdf)) {
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'ghostscript'; stderr = "input missing: $InputPdf"; command = @() }
    }

    $args = @(
        '-sDEVICE=pdfwrite',
        '-dSAFER',
        '-dBATCH',
        '-dNOPAUSE',
        '-dQUIET',
        '-dCompatibilityLevel=1.7',
        '-dColorConversionStrategy=/LeaveColorUnchanged',
        '-dDownsampleColorImages=true',
        '-dDownsampleGrayImages=true',
        ('-dDownsampleMonoImages=' + ($(if ($DownsampleMono) { 'true' } else { 'false' }))),
        ('-dColorImageResolution=' + $ColorDpi),
        ('-dGrayImageResolution=' + $GrayDpi),
        '-dAutoRotatePages=/None',
        ('-sOutputFile=' + $OutputPdf),
        '--',
        $InputPdf
    )

    $stderr = $null
    $rc = -1
    try {
        $stderrFile = [System.IO.Path]::GetTempFileName()
        try {
            & $GhostscriptExe @args 2> $stderrFile | Out-Null
            $rc = $LASTEXITCODE
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        } finally {
            Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
        }
    } catch {
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'ghostscript'; stderr = $_.Exception.Message; command = $args }
    }

    return [pscustomobject]@{
        success  = ($rc -eq 0 -and (Test-Path -LiteralPath $OutputPdf))
        exitCode = $rc
        tool     = 'ghostscript'
        stderr   = $stderr
        command  = $args
    }
}
