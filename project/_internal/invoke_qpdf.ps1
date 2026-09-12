# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    qpdf wrapper. Lossless optimization with object streams + flate recompress.
    --linearize is NOT default (web optimization, not file-size).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Qpdf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$QpdfExe,
        [Parameter(Mandatory)][string]$InputPdf,
        [Parameter(Mandatory)][string]$OutputPdf,
        [switch]$Linearize
    )

    if (-not (Test-Path -LiteralPath $QpdfExe)) {
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'qpdf'; stderr = "qpdf missing: $QpdfExe"; command = @() }
    }
    if (-not (Test-Path -LiteralPath $InputPdf)) {
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'qpdf'; stderr = "input missing: $InputPdf"; command = @() }
    }

    $args = @(
        '--object-streams=generate',
        '--recompress-flate',
        '--compression-level=9'
    )
    if ($Linearize) { $args += '--linearize' }
    $args += @('--', $InputPdf, $OutputPdf)

    $stderr = $null
    $rc = -1
    try {
        $stderrFile = [System.IO.Path]::GetTempFileName()
        try {
            & $QpdfExe @args 2> $stderrFile | Out-Null
            $rc = $LASTEXITCODE
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        } finally {
            Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
        }
    } catch {
        return [pscustomobject]@{ success = $false; exitCode = -1; tool = 'qpdf'; stderr = $_.Exception.Message; command = $args }
    }

    # qpdf exit code 0 = success, 3 = warnings (still produced output).
    $ok = (($rc -eq 0) -or ($rc -eq 3)) -and (Test-Path -LiteralPath $OutputPdf)

    return [pscustomobject]@{
        success  = $ok
        exitCode = $rc
        tool     = 'qpdf'
        stderr   = $stderr
        command  = $args
    }
}
