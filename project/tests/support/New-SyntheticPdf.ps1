Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SyntheticPdf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidateRange(1, 2000)][int]$PageCount = 1,
        [decimal[]]$MediaBox = @(0, 0, 612, 792),
        [hashtable]$RotationByPage = @{},
        [hashtable]$CropBoxByPage = @{},
        [switch]$IncludeRasterImage,
        [ValidateRange(1, 4000)][int]$RasterWidth = 120,
        [ValidateRange(1, 4000)][int]$RasterHeight = 160,
        [switch]$IncludeAcroForm,
        [switch]$IncludeAttachmentsOutlinesLinks,
        [long]$TargetBytes = 0
    )

    if ($MediaBox.Count -ne 4) { throw 'MediaBox must contain exactly four numbers.' }
    $mediaBoxText = @($MediaBox | ForEach-Object { $_.ToString([Globalization.CultureInfo]::InvariantCulture) }) -join ' '

    $objects = [System.Collections.Generic.List[string]]::new()
    $kids = [System.Collections.Generic.List[string]]::new()
    $fontId = 3 + ($PageCount * 2)
    $nextObjectId = $fontId + 1
    $imageId = if ($IncludeRasterImage) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }
    $acroFormId = if ($IncludeAcroForm) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }
    $fieldId = if ($IncludeAcroForm) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }
    $attachmentStreamId = if ($IncludeAttachmentsOutlinesLinks) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }
    $fileSpecId = if ($IncludeAttachmentsOutlinesLinks) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }
    $namesId = if ($IncludeAttachmentsOutlinesLinks) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }
    $outlineItemId = if ($IncludeAttachmentsOutlinesLinks) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }
    $outlinesId = if ($IncludeAttachmentsOutlinesLinks) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }
    $linkId = if ($IncludeAttachmentsOutlinesLinks) { $id = $nextObjectId; $nextObjectId++; $id } else { 0 }

    $catalogExtras = [System.Collections.Generic.List[string]]::new()
    if ($IncludeAcroForm) { $catalogExtras.Add("/AcroForm $acroFormId 0 R") }
    if ($IncludeAttachmentsOutlinesLinks) {
        $catalogExtras.Add("/Names << /EmbeddedFiles $namesId 0 R >>")
        $catalogExtras.Add("/Outlines $outlinesId 0 R")
        $catalogExtras.Add('/PageMode /UseOutlines')
    }
    $objects.Add("<< /Type /Catalog /Pages 2 0 R $($catalogExtras -join ' ') >>")
    for ($page = 1; $page -le $PageCount; $page++) {
        $pageObjectId = 3 + (($page - 1) * 2)
        $contentObjectId = $pageObjectId + 1
        $kids.Add("$pageObjectId 0 R")
    }
    $objects.Add("<< /Type /Pages /Kids [ $($kids -join ' ') ] /Count $PageCount >>")

    $targetPerPage = if ($TargetBytes -gt 0) { [math]::Max(0, [math]::Floor($TargetBytes / $PageCount) - 1024) } else { 0 }
    $unit = "q 1 0 0 1 0 0 cm Q`n"
    $unitBytes = [Text.Encoding]::ASCII.GetByteCount($unit)
    for ($page = 1; $page -le $PageCount; $page++) {
        $pageObjectId = 3 + (($page - 1) * 2)
        $contentObjectId = $pageObjectId + 1
        $content = "BT /F1 12 Tf 72 720 Td (Synthetic page $page) Tj ET`n"
        if ($IncludeRasterImage) { $content += "q 480 0 0 640 66 60 cm /Im1 Do Q`n" }
        if ($targetPerPage -gt 0) {
            $prefixBytes = [Text.Encoding]::ASCII.GetByteCount($content)
            $repeatCount = [math]::Max(0, [math]::Ceiling(($targetPerPage - $prefixBytes) / $unitBytes))
            $builder = [Text.StringBuilder]::new($prefixBytes + ($repeatCount * $unitBytes))
            [void]$builder.Append($content)
            for ($i = 0; $i -lt $repeatCount; $i++) { [void]$builder.Append($unit) }
            $content = $builder.ToString()
        }
        $rotation = if ($RotationByPage.ContainsKey($page)) { " /Rotate $([int]$RotationByPage[$page])" } else { '' }
        $cropBox = if ($CropBoxByPage.ContainsKey($page)) {
            $box = @($CropBoxByPage[$page])
            if ($box.Count -ne 4) { throw "CropBoxByPage[$page] must contain exactly four numbers." }
            " /CropBox [$($box -join ' ')]"
        } else { '' }
        $xObject = if ($IncludeRasterImage) { " /XObject << /Im1 $imageId 0 R >>" } else { '' }
        $annotations = [System.Collections.Generic.List[string]]::new()
        if ($page -eq 1 -and $IncludeAcroForm) { $annotations.Add("$fieldId 0 R") }
        if ($page -eq 1 -and $IncludeAttachmentsOutlinesLinks) { $annotations.Add("$linkId 0 R") }
        $annots = if ($annotations.Count -gt 0) { " /Annots [ $($annotations -join ' ') ]" } else { '' }
        $pageObject = "<< /Type /Page /Parent 2 0 R /MediaBox [$mediaBoxText]$cropBox /Resources << /Font << /F1 $fontId 0 R >>$xObject >> /Contents $contentObjectId 0 R$rotation$annots >>"
        $objects.Add($pageObject)
        $contentLength = [Text.Encoding]::ASCII.GetByteCount($content)
        $objects.Add("<< /Length $contentLength >>`nstream`n$content`nendstream")
    }
    $objects.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    if ($IncludeRasterImage) {
        $pixels = ('7f' * ($RasterWidth * $RasterHeight)) + '>'
        $objects.Add("<< /Type /XObject /Subtype /Image /Width $RasterWidth /Height $RasterHeight /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length $($pixels.Length) >>`nstream`n$pixels`nendstream")
    }
    if ($IncludeAcroForm) {
        $objects.Add("<< /Fields [ $fieldId 0 R ] /NeedAppearances true >>")
        $objects.Add("<< /Type /Annot /Subtype /Widget /FT /Tx /T (SyntheticField) /Rect [72 650 240 680] /P 3 0 R /V (fixture-value) >>")
    }
    if ($IncludeAttachmentsOutlinesLinks) {
        $attachmentText = 'Synthetic attachment fixture.'
        $objects.Add("<< /Type /EmbeddedFile /Length $($attachmentText.Length) >>`nstream`n$attachmentText`nendstream")
        $objects.Add("<< /Type /Filespec /F (fixture.txt) /UF (fixture.txt) /EF << /F $attachmentStreamId 0 R >> >>")
        $objects.Add("<< /Names [(fixture.txt) $fileSpecId 0 R] >>")
        $objects.Add("<< /Title (Synthetic outline) /Parent $outlinesId 0 R /Dest [3 0 R /Fit] >>")
        $objects.Add("<< /Type /Outlines /First $outlineItemId 0 R /Last $outlineItemId 0 R /Count 1 >>")
        $objects.Add('<< /Type /Annot /Subtype /Link /Rect [72 700 300 735] /Border [0 0 1] /A << /S /URI /URI (https://example.invalid/fixture) >> >>')
    }

    if ($objects.Count -ne ($nextObjectId - 1)) {
        throw "Synthetic PDF object allocation mismatch: expected $($nextObjectId - 1), got $($objects.Count)."
    }

    $chunks = [System.Collections.Generic.List[string]]::new()
    $header = "%PDF-1.4`n"
    $chunks.Add($header)
    $offsets = [System.Collections.Generic.List[long]]::new()
    $offsets.Add(0L)
    $offset = [long][Text.Encoding]::ASCII.GetByteCount($header)
    for ($index = 0; $index -lt $objects.Count; $index++) {
        $objectText = "{0} 0 obj`n{1}`nendobj`n" -f ($index + 1), $objects[$index]
        $chunks.Add($objectText)
        $offsets.Add($offset)
        $offset += [Text.Encoding]::ASCII.GetByteCount($objectText)
    }
    $xrefOffset = $offset
    $xref = "xref`n0 $($objects.Count + 1)`n0000000000 65535 f `n"
    for ($index = 1; $index -lt $offsets.Count; $index++) {
        $xref += ("{0:0000000000} 00000 n `n" -f $offsets[$index])
    }
    $trailer = "trailer`n<< /Size $($objects.Count + 1) /Root 1 0 R >>`nstartxref`n$xrefOffset`n%%EOF`n"
    $chunks.Add($xref + $trailer)
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllBytes($OutputPath, [Text.Encoding]::ASCII.GetBytes(($chunks -join '')))
    return Get-Item -LiteralPath $OutputPath -Force
}
