# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Bounded, normalized PDF page-structure snapshots.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-StructureBox {
    param([Parameter(Mandatory)][string[]]$Values)
    if ($Values.Count -lt 4) { return $null }
    try {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        return @([decimal]::Parse($Values[0], [Globalization.NumberStyles]::Float, $inv),
                 [decimal]::Parse($Values[1], [Globalization.NumberStyles]::Float, $inv),
                 [decimal]::Parse($Values[2], [Globalization.NumberStyles]::Float, $inv),
                 [decimal]::Parse($Values[3], [Globalization.NumberStyles]::Float, $inv))
    } catch { return $null }
}

function ConvertTo-NormalizedRotation {
    param([object]$Value)
    try {
        $n = [int]$Value
        $n = $n % 360
        if ($n -lt 0) { $n += 360 }
        if ($n -notin @(0,90,180,270)) { return $null }
        return $n
    } catch { return $null }
}

function Get-PdfInfoPageRecords {
    param([Parameter(Mandatory)][string[]]$Lines)
    $records = @{}
    $globalMedia = $null
    $globalCrop = $null
    foreach ($line in $Lines) {
        $text = [string]$line
        if ($text -match '^\s*Pages:\s*(?<pages>\d+)') { continue }
        if ($text -match '^\s*Page\s+(?<page>\d+)\s+MediaBox:\s+(?<a>-?\d+(?:\.\d+)?)\s+(?<b>-?\d+(?:\.\d+)?)\s+(?<c>-?\d+(?:\.\d+)?)\s+(?<d>-?\d+(?:\.\d+)?)') {
            if (-not $records.ContainsKey([int]$Matches.page)) { $records[[int]$Matches.page] = [ordered]@{} }
            $records[[int]$Matches.page].media_box = ConvertTo-StructureBox @($Matches.a,$Matches.b,$Matches.c,$Matches.d)
        } elseif ($text -match '^\s*Page\s+(?<page>\d+)\s+CropBox:\s+(?<a>-?\d+(?:\.\d+)?)\s+(?<b>-?\d+(?:\.\d+)?)\s+(?<c>-?\d+(?:\.\d+)?)\s+(?<d>-?\d+(?:\.\d+)?)') {
            if (-not $records.ContainsKey([int]$Matches.page)) { $records[[int]$Matches.page] = [ordered]@{} }
            $records[[int]$Matches.page].crop_box = ConvertTo-StructureBox @($Matches.a,$Matches.b,$Matches.c,$Matches.d)
        } elseif ($text -match '^\s*MediaBox:\s+(?<a>-?\d+(?:\.\d+)?)\s+(?<b>-?\d+(?:\.\d+)?)\s+(?<c>-?\d+(?:\.\d+)?)\s+(?<d>-?\d+(?:\.\d+)?)') {
            $globalMedia = ConvertTo-StructureBox @($Matches.a,$Matches.b,$Matches.c,$Matches.d)
        } elseif ($text -match '^\s*CropBox:\s+(?<a>-?\d+(?:\.\d+)?)\s+(?<b>-?\d+(?:\.\d+)?)\s+(?<c>-?\d+(?:\.\d+)?)\s+(?<d>-?\d+(?:\.\d+)?)') {
            $globalCrop = ConvertTo-StructureBox @($Matches.a,$Matches.b,$Matches.c,$Matches.d)
        }
    }
    return [pscustomobject]@{ records = $records; global_media = $globalMedia; global_crop = $globalCrop }
}

function Get-PdfInfoRotationMapFromLines {
    param([Parameter(Mandatory)][string[]]$Lines,[Parameter(Mandatory)][int]$PageCount)
    $map = @{}
    $currentPage = $null
    foreach ($line in $Lines) {
        $text = [string]$line
        if ($text -match '^\s*Page\s+(?<page>\d+)\s+(?:size|rot|MediaBox|CropBox):') {
            $currentPage = [int]$Matches.page
        }
        if ($text -match '^\s*Page\s+(?<page>\d+)\s+rot:\s*(?<value>-?\d+)') {
            $currentPage = [int]$Matches.page
            $rotation = ConvertTo-NormalizedRotation -Value $Matches.value
            if ($null -eq $rotation) { return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-indeterminate'); detector = 'pdfinfo' } }
            $map[$currentPage] = $rotation
        } elseif ($text -match '^\s*Page\s+rot:\s*(?<value>-?\d+)') {
            if ($null -eq $currentPage) { continue }
            $rotation = ConvertTo-NormalizedRotation -Value $Matches.value
            if ($null -eq $rotation) { return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-indeterminate'); detector = 'pdfinfo' } }
            $map[$currentPage] = $rotation
        }
    }
    if ($map.Count -ne $PageCount -or @($map.Keys | Where-Object { $_ -lt 1 -or $_ -gt $PageCount }).Count -gt 0) {
        return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-incomplete'); detector = 'pdfinfo' }
    }
    return [pscustomobject]@{ available = $true; map = $map; warnings = @(); detector = 'pdfinfo' }
}

function Get-PdfInfoRotationMap {
    param([Parameter(Mandatory)][string]$PdfInfoExe,[Parameter(Mandatory)][string]$PdfPath,[Parameter(Mandatory)][int]$PageCount)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($PdfInfoExe) -or -not (Test-Path -LiteralPath $PdfInfoExe -PathType Leaf) -or $PageCount -le 0) {
        return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-unavailable'); detector = 'unavailable' }
    }
    try {
        $args = @('-f','1','-l',[string]$PageCount,'-box','--',$PdfPath)
        $lines = @(& $PdfInfoExe @args 2>&1)
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-failed'); detector = 'pdfinfo' } }
        return Get-PdfInfoRotationMapFromLines -Lines $lines -PageCount $PageCount
    } catch {
        return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-failed'); detector = 'pdfinfo' }
    }
}

function Get-PdfRotationMap {
    param([Parameter()][string]$QpdfExe,[Parameter()][string]$PdfInfoExe,[Parameter(Mandatory)][string]$PdfPath,[int]$PageCount = 0)
    $map = @{}
    if (-not [string]::IsNullOrWhiteSpace($PdfInfoExe) -and $PageCount -gt 0) {
        $pdfInfoResult = Get-PdfInfoRotationMap -PdfInfoExe $PdfInfoExe -PdfPath $PdfPath -PageCount $PageCount
        if ($pdfInfoResult.available) { return $pdfInfoResult }
    }
    if ([string]::IsNullOrWhiteSpace($QpdfExe) -or -not (Test-Path -LiteralPath $QpdfExe)) {
        return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-unavailable'); detector = 'unavailable' }
    }
    try {
        $out = @(& $QpdfExe '--show-pages' '--' $PdfPath 2>&1)
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-failed'); detector = 'qpdf-show-pages' } }
        $current = $null
        foreach ($line in $out) {
            $text = [string]$line
            if ($text -match 'page\s+(?<page>\d+)') { $current = [int]$Matches.page }
            if ($text -match '(?:rotation|rotate|/Rotate)\s*[:= ]\s*(?<value>-?\d+)') {
                $rotation = ConvertTo-NormalizedRotation -Value $Matches.value
                if ($null -ne $rotation) {
                    if ($null -eq $current) { $current = $map.Count + 1 }
                    $map[$current] = $rotation
                }
            }
        }
        if ($map.Count -eq 0) { return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-indeterminate'); detector = 'qpdf-show-pages' } }
        return [pscustomobject]@{ available = $true; map = $map; warnings = @(); detector = 'qpdf-show-pages' }
    } catch { return [pscustomobject]@{ available = $false; map = $map; warnings = @('rotate-detector-failed'); detector = 'qpdf-show-pages' } }
}

function Get-PdfStructureSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [Parameter(Mandatory)][string]$PdfInfoExe,
        [string]$QpdfExe,
        [int]$PageCount = 0
    )
    if (-not (Test-Path -LiteralPath $PdfPath -PathType Leaf)) {
        return [pscustomobject]@{ status = 'indeterminate'; reasons = @('input-missing'); page_count = 0; pages = @(); encryption = 'unknown' }
    }
    $args = [System.Collections.Generic.List[string]]::new()
    if ($PageCount -gt 0) { $args.Add('-f'); $args.Add('1'); $args.Add('-l'); $args.Add([string]$PageCount) }
    $args.Add('-box'); $args.Add('--'); $args.Add($PdfPath)
    try { $infoLines = @(& $PdfInfoExe @args 2>&1); $rc = $LASTEXITCODE } catch { $infoLines = @($_.Exception.Message); $rc = -1 }
    if ($rc -ne 0) {
        $lower = (($infoLines | ForEach-Object { [string]$_ }) -join ' ').ToLowerInvariant()
        $reason = if ($lower -match 'encrypt|password') { 'encrypted' } else { 'pdfinfo-failed' }
        return [pscustomobject]@{ status = 'indeterminate'; reasons = @($reason); page_count = 0; pages = @(); encryption = if ($reason -eq 'encrypted') { 'present' } else { 'unknown' } }
    }
    $joined = $infoLines -join "`n"
    $pagesCount = 0
    if ($joined -match '(?m)^\s*Pages:\s*(\d+)') { $pagesCount = [int]$Matches[1] }
    if ($PageCount -gt 0 -and $pagesCount -eq 0) { $pagesCount = $PageCount }
    $parsed = Get-PdfInfoPageRecords -Lines $infoLines
    # The same pdfinfo -f 1 -l N -box output already contains every page's
    # rotation. Parse it here so each snapshot launches pdfinfo only once.
    $rotations = Get-PdfInfoRotationMapFromLines -Lines $infoLines -PageCount $pagesCount
    if (-not $rotations.available) {
        $rotations = Get-PdfRotationMap -QpdfExe $QpdfExe -PdfInfoExe '' -PdfPath $PdfPath -PageCount $pagesCount
    }
    $pages = @()
    for ($i = 1; $i -le $pagesCount; $i++) {
        $record = if ($parsed.records.ContainsKey($i)) { $parsed.records[$i] } else { [ordered]@{} }
        $media = if ($record.Contains('media_box')) { $record.media_box } else { $parsed.global_media }
        if ($null -eq $media) { $media = @(0,0,0,0) }
        $crop = if ($record.Contains('crop_box')) { $record.crop_box } else { $parsed.global_crop }
        if ($null -eq $crop) { $crop = $media }
        $rotate = if ($rotations.map.ContainsKey($i)) { $rotations.map[$i] } else { 0 }
        $pages += [pscustomobject]@{ page = $i; media_box = @($media); crop_box = @($crop); rotate = $rotate }
    }
    $reasons = @($rotations.warnings)
    if ($pagesCount -le 0 -or $pages.Count -ne $pagesCount) { $reasons += 'page-structure-incomplete' }
    return [pscustomobject]@{
        status = if ($reasons.Count -eq 0) { 'verified' } else { 'indeterminate' }
        reasons = @($reasons)
        page_count = $pagesCount
        pages = @($pages)
        encryption = if ($joined -match '(?im)^\s*Encrypted:\s*yes') { 'present' } else { 'absent' }
        rotate_detector = if ($rotations.available) { [string]$rotations.detector } else { 'unavailable' }
    }
}

function Test-StructureBoxEqual {
    param([object[]]$Left,[object[]]$Right,[decimal]$Tolerance = 0.01)
    if ($null -eq $Left -or $null -eq $Right -or $Left.Count -ne 4 -or $Right.Count -ne 4) { return $false }
    for ($i=0; $i -lt 4; $i++) { if ([math]::Abs([decimal]$Left[$i] - [decimal]$Right[$i]) -gt $Tolerance) { return $false } }
    return $true
}

function Compare-PdfStructureSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Before,[Parameter(Mandatory)][object]$After,[decimal]$Tolerance = 0.01)
    $reasons = @()
    $pageEqual = ([int]$Before.page_count -eq [int]$After.page_count)
    if (-not $pageEqual) { $reasons += 'page-count-mismatch' }
    $mediaEqual = $true; $cropEqual = $true; $rotateEqual = $true
    $count = [math]::Min(@($Before.pages).Count,@($After.pages).Count)
    for ($i=0; $i -lt $count; $i++) {
        if (-not (Test-StructureBoxEqual @($Before.pages[$i].media_box) @($After.pages[$i].media_box) -Tolerance $Tolerance)) { $mediaEqual = $false }
        if (-not (Test-StructureBoxEqual @($Before.pages[$i].crop_box) @($After.pages[$i].crop_box) -Tolerance $Tolerance)) { $cropEqual = $false }
        if ((ConvertTo-NormalizedRotation $Before.pages[$i].rotate) -ne (ConvertTo-NormalizedRotation $After.pages[$i].rotate)) { $rotateEqual = $false }
    }
    if (-not $mediaEqual) { $reasons += 'media-box-mismatch' }
    if (-not $cropEqual) { $reasons += 'crop-box-mismatch' }
    if (-not $rotateEqual) { $reasons += 'rotate-mismatch' }
    return [pscustomobject]@{
        equal = [bool]($pageEqual -and $mediaEqual -and $cropEqual -and $rotateEqual)
        page_count_equal = $pageEqual; media_box_equal = $mediaEqual; crop_box_equal = $cropEqual; rotate_equal = $rotateEqual
        reasons = @($reasons)
    }
}
