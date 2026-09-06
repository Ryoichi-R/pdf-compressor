# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Analyze a PDF via pdfinfo + pdfimages -list and produce metrics for
    strategy selection.

.OUTPUTS
    PSCustomObject with: pageCount, fileSize, imageCount, imageBytes,
    imageRatio, avgDpi, hasImages, encodings (hashtable),
    pageImageDensity, warnings (array), error (string|null).

    On unrecoverable analysis errors (encrypted/corrupted) returns object
    with $error set; caller should treat the file as [FAIL].
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-SizeToBytes {
    <#
    .SYNOPSIS
        Normalize the "size" column from `pdfimages -list`. Handles plain bytes,
        B/K/M/G suffixes, and IEC KiB/MiB/GiB. Returns 0 with a warning marker
        for "-" or missing values.
    #>
    param([Parameter(Mandatory)][string]$Raw)

    $v = $Raw.Trim()
    if ([string]::IsNullOrEmpty($v) -or $v -eq '-') { return @{ bytes = 0L; warn = $true } }

    $upper = $v.ToUpperInvariant()
    # Extract numeric prefix and trailing alpha suffix.
    if ($upper -notmatch '^([0-9]+(?:\.[0-9]+)?)([A-Z]*)$') {
        return @{ bytes = 0L; warn = $true }
    }
    $num = [double]$Matches[1]
    $suffix = $Matches[2]

    $table = @{
        ''    = 1.0
        'B'   = 1.0
        'K'   = 1024.0
        'KB'  = 1024.0
        'KIB' = 1024.0
        'M'   = 1048576.0
        'MB'  = 1048576.0
        'MIB' = 1048576.0
        'G'   = 1073741824.0
        'GB'  = 1073741824.0
        'GIB' = 1073741824.0
    }

    if (-not $table.ContainsKey($suffix)) {
        return @{ bytes = 0L; warn = $true }
    }
    $bytes = [long]([math]::Round($num * $table[$suffix]))
    return @{ bytes = $bytes; warn = $false }
}

function ConvertFrom-PdfImagesList {
    <#
    .SYNOPSIS
        Parse the output of `pdfimages -list <pdf>`. Returns array of records
        with: page, type, width, height, encoding, xppi, yppi, bytes.
    #>
    param([Parameter(Mandatory)][string[]]$Lines)

    $records = @()
    $headerSeen = $false
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*---') { continue }
        if (-not $headerSeen) {
            if ($line -match 'page\s+num\s+type') { $headerSeen = $true }
            continue
        }
        # Split on whitespace runs. Expected columns (Poppler default):
        # page num type width height color comp bpc enc interp object ID x-ppi y-ppi size ratio
        $cols = -split $line
        if ($cols.Count -lt 14) { continue }

        $rec = [pscustomobject]@{
            page     = [int]$cols[0]
            type     = $cols[2].ToLowerInvariant()
            width    = if ($cols[3] -match '^[0-9]+$') { [int]$cols[3] } else { 0 }
            height   = if ($cols[4] -match '^[0-9]+$') { [int]$cols[4] } else { 0 }
            encoding = $cols[8].ToLowerInvariant()
            xppi     = $cols[12]
            yppi     = $cols[13]
            sizeRaw  = if ($cols.Count -ge 15) { $cols[14] } else { '-' }
        }
        $records += $rec
    }
    return ,$records
}

function Get-PdfInfo {
    param(
        [Parameter(Mandatory)][string]$PdfInfoExe,
        [Parameter(Mandatory)][string]$PdfPath
    )
    $out = & $PdfInfoExe -- $PdfPath 2>&1
    $rc = $LASTEXITCODE
    return @{ output = $out; rc = $rc }
}

function Get-PdfImagesList {
    param(
        [Parameter(Mandatory)][string]$PdfImagesExe,
        [Parameter(Mandatory)][string]$PdfPath
    )
    $out = & $PdfImagesExe -list -- $PdfPath 2>&1
    $rc = $LASTEXITCODE
    return @{ output = $out; rc = $rc }
}

function Get-PdfMetrics {
    <#
    .SYNOPSIS
        Top-level analyzer. Calls pdfinfo + pdfimages and computes metrics.
    .PARAMETER PdfPath
        Absolute path to input PDF.
    .PARAMETER PdfInfoExe
        Resolved path to pdfinfo.exe.
    .PARAMETER PdfImagesExe
        Resolved path to pdfimages.exe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [Parameter(Mandatory)][string]$PdfInfoExe,
        [Parameter(Mandatory)][string]$PdfImagesExe
    )

    if (-not (Test-Path -LiteralPath $PdfPath)) {
        return [pscustomobject]@{
            error = 'input-missing'
            tool  = 'analyze'
        }
    }

    $fileInfo = Get-Item -LiteralPath $PdfPath
    $fileSize = [long]$fileInfo.Length

    # pdfinfo
    $info = Get-PdfInfo -PdfInfoExe $PdfInfoExe -PdfPath $PdfPath
    if ($info.rc -ne 0) {
        $outStr = ($info.output | Out-String).ToLowerInvariant()
        $reason = 'unknown'
        if ($outStr -match 'encrypted|password') { $reason = 'encrypted' }
        elseif ($outStr -match 'damaged|invalid|syntax') { $reason = 'corrupted' }
        elseif ($outStr -match 'permission') { $reason = 'permission-denied' }
        return [pscustomobject]@{
            error = $reason
            tool  = 'pdfinfo'
        }
    }

    $pageCount = 0
    foreach ($line in ($info.output -split "`r?`n")) {
        if ($line -match '^Pages:\s+([0-9]+)') {
            $pageCount = [int]$Matches[1]
            break
        }
    }

    # pdfimages -list
    $imgs = Get-PdfImagesList -PdfImagesExe $PdfImagesExe -PdfPath $PdfPath
    if ($imgs.rc -ne 0) {
        $outStr = ($imgs.output | Out-String).ToLowerInvariant()
        $reason = 'unknown'
        if ($outStr -match 'encrypted|password') { $reason = 'encrypted' }
        elseif ($outStr -match 'damaged|invalid|syntax') { $reason = 'corrupted' }
        elseif ($outStr -match 'permission') { $reason = 'permission-denied' }
        return [pscustomobject]@{
            error = $reason
            tool  = 'pdfimages'
        }
    }

    $lines = @($imgs.output | ForEach-Object { [string]$_ })
    $records = ConvertFrom-PdfImagesList -Lines $lines

    $warnings = @()
    $maskTypes = @('mask', 'smask', 'stencil')

    $imageBytes = 0L
    $dpis = @()
    $encodings = @{}
    $imageCount = 0
    foreach ($r in $records) {
        $isMask = $maskTypes -contains $r.type
        $sz = Convert-SizeToBytes -Raw $r.sizeRaw
        if ($sz.warn) { $warnings += "size-parse-failed:p$($r.page)" }

        if ($isMask) {
            # Track mask bytes separately but exclude from primary metrics.
            continue
        }

        $imageCount++
        $imageBytes += [long]$sz.bytes

        if ($encodings.ContainsKey($r.encoding)) {
            $encodings[$r.encoding]++
        } else {
            $encodings[$r.encoding] = 1
        }

        # Parse DPIs. Reject -, 0, negatives, < 72, and > 10000.
        $xVal = $null; $yVal = $null
        if ($r.xppi -match '^-?[0-9]+(?:\.[0-9]+)?$') { $xVal = [double]$r.xppi }
        if ($r.yppi -match '^-?[0-9]+(?:\.[0-9]+)?$') { $yVal = [double]$r.yppi }
        if ($null -ne $xVal -and $null -ne $yVal -and
            $xVal -ge 72 -and $yVal -ge 72 -and
            $xVal -le 10000 -and $yVal -le 10000) {
            $dpis += [math]::Min($xVal, $yVal)
        }
    }

    $imageRatio = 0.0
    if ($fileSize -gt 0) {
        $imageRatio = [math]::Min(1.0, [double]$imageBytes / [double]$fileSize)
    }

    $avgDpi = $null
    if ($dpis.Count -gt 0) {
        $sorted = @($dpis | Sort-Object)
        $mid = [int][math]::Floor($sorted.Count / 2)
        if ($sorted.Count % 2 -eq 1) {
            $avgDpi = [double]$sorted[$mid]
        } else {
            $avgDpi = ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0
        }
    }

    $pageImageDensity = 0.0
    if ($pageCount -gt 0) {
        $pageImageDensity = [double]$imageCount / [double]$pageCount
    }

    return [pscustomobject]@{
        error            = $null
        pageCount        = $pageCount
        fileSize         = $fileSize
        imageCount       = $imageCount
        imageBytes       = $imageBytes
        imageRatio       = [math]::Round($imageRatio, 4)
        avgDpi           = $avgDpi
        hasImages        = ($imageCount -gt 0)
        encodings        = $encodings
        pageImageDensity = [math]::Round($pageImageDensity, 4)
        warnings         = $warnings
    }
}
