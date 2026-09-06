# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Lossy full-page rasterizer wrapper for PDFs.

.DESCRIPTION
    Uses Ghostscript pdfimage24 to rasterize each page into a full-page image
    PDF. This intentionally loses text/vector/searchability in exchange for
    file-size reduction on vector-heavy PDFs that normal image downsampling
    cannot shrink.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-LossyRaster {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GhostscriptExe,
        [Parameter(Mandatory)][string]$InputPdf,
        [Parameter(Mandatory)][string]$OutputPdf,
        [Parameter(Mandatory)][int]$RasterDpi,
        [Parameter(Mandatory)][int]$JpegQuality
    )

    if ($RasterDpi -lt 72 -or $RasterDpi -gt 300) {
        throw "invoke_lossy_raster: raster_dpi out of range: $RasterDpi"
    }
    if ($JpegQuality -lt 1 -or $JpegQuality -gt 100) {
        throw "invoke_lossy_raster: jpeg_quality out of range: $JpegQuality"
    }
    if (-not (Test-Path -LiteralPath $GhostscriptExe)) {
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'lossy-raster'; stderr = "ghostscript missing: $GhostscriptExe"; command = @() }
    }
    if (-not (Test-Path -LiteralPath $InputPdf)) {
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'lossy-raster'; stderr = "input missing: $InputPdf"; command = @() }
    }

    $args = @(
        '-dSAFER',
        '-dBATCH',
        '-dNOPAUSE',
        '-dQUIET',
        '-sDEVICE=pdfimage24',
        ('-r' + $RasterDpi),
        ('-dJPEGQ=' + $JpegQuality),
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
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'lossy-raster'; stderr = $_.Exception.Message; command = $args }
    }

    return [pscustomobject]@{
        success  = ($rc -eq 0 -and (Test-Path -LiteralPath $OutputPdf))
        exitCode = $rc
        tool     = 'lossy-raster'
        stderr   = $stderr
        command  = $args
    }
}
