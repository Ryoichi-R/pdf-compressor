Set-StrictMode -Version Latest

BeforeAll {
    $internalRoot = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internalRoot 'pdf-structure.ps1')
    . (Join-Path $internalRoot 'validate_output.ps1')
    . (Join-Path $internalRoot 'inspect_pdf_features.ps1')

    function New-FakeQpdf {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][int]$ExitCode,
            [string]$Output = ''
        )
        $literal = $Output.Replace("'", "''")
        @"
param(
    [Parameter(ValueFromRemainingArguments=`$true)]
    [string[]]`$Arguments
)
if ('$literal' -ne '') { Write-Output '$literal' }
exit $ExitCode
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
        return $Path
    }

    function New-WarningQpdf {
        param([Parameter(Mandatory)][string]$Path)
        @'
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)
$pdf = [string]$Arguments[-1]
if ($pdf -like '*candidate-new-warning.pdf') {
    Write-Output 'WARNING: stream issue at offset 123 object 7 0'
} elseif ($pdf -like '*candidate-decreased-warning.pdf') {
    Write-Output 'WARNING: syntax warning at offset 999 object 8 0'
} else {
    Write-Output 'WARNING: syntax warning at offset 10 object 4 0'
}
exit 3
'@ | Set-Content -LiteralPath $Path -Encoding UTF8
        return $Path
    }

    function New-TestSnapshot {
        param([int]$PageCount = 1,[object[]]$Pages)
        if ($null -eq $Pages) {
            $Pages = @([pscustomobject]@{ media_box = @(0,0,612,792); crop_box = @(0,0,612,792); rotate = 0 })
        }
        return [pscustomobject]@{ status = 'verified'; page_count = $PageCount; pages = @($Pages) }
    }
}

Describe 'Invoke-QpdfCheck exit contract' {
    It 'maps qpdf exit 0, 2, 3 and unexpected exit codes' {
        $cases = @(
            @{ code = 0; status = 'clean' },
            @{ code = 2; status = 'error' },
            @{ code = 3; status = 'warning' },
            @{ code = 7; status = 'tool-failure' }
        )
        foreach ($case in $cases) {
            $fake = New-FakeQpdf -Path (Join-Path $TestDrive ("qpdf-{0}.ps1" -f $case.code)) -ExitCode $case.code -Output 'WARNING: syntax warning'
            $result = Invoke-QpdfCheck -QpdfExe $fake -PdfPath (Join-Path $TestDrive 'input.pdf')
            $result.exit_code | Should -Be $case.code
            $result.status | Should -Be $case.status
        }
    }
}

Describe 'qpdf warning normalization and delta policy' {
    It 'accepts the same warning category despite offset and object changes' {
        $fake = New-WarningQpdf -Path (Join-Path $TestDrive 'qpdf-warning.ps1')
        $result = Validate-CompressedPdf -InputPdf (Join-Path $TestDrive 'input.pdf') -CandidatePdf (Join-Path $TestDrive 'candidate-same-warning.pdf') -QpdfExe $fake -PdfInfoExe 'unused' -SafetyMode Safe
        $result.accepted | Should -BeTrue
        $result.status | Should -Be 'verified'
        $result.qpdf_check.new_warnings | Should -BeNullOrEmpty
    }

    It 'rejects a new warning category in Safe mode' {
        $fake = New-WarningQpdf -Path (Join-Path $TestDrive 'qpdf-warning.ps1')
        $result = Validate-CompressedPdf -InputPdf (Join-Path $TestDrive 'input.pdf') -CandidatePdf (Join-Path $TestDrive 'candidate-new-warning.pdf') -QpdfExe $fake -PdfInfoExe 'unused' -SafetyMode Safe
        $result.accepted | Should -BeFalse
        $result.status | Should -Be 'rejected'
        $result.reasons | Should -Contain 'new-qpdf-warning:stream'
    }

    It 'accepts a warning-category decrease without inventing a new warning' {
        $fake = New-WarningQpdf -Path (Join-Path $TestDrive 'qpdf-warning.ps1')
        $result = Validate-CompressedPdf -InputPdf (Join-Path $TestDrive 'input.pdf') -CandidatePdf (Join-Path $TestDrive 'candidate-decreased-warning.pdf') -QpdfExe $fake -PdfInfoExe 'unused' -SafetyMode Safe
        $result.accepted | Should -BeTrue
        $result.status | Should -Be 'verified'
    }

    It 'rejects an unclassified warning in Safe mode even when input and output match' {
        $fake = New-FakeQpdf -Path (Join-Path $TestDrive 'qpdf-unclassified.ps1') -ExitCode 3 -Output 'WARNING: an unclassified condition'
        $result = Validate-CompressedPdf -InputPdf (Join-Path $TestDrive 'input.pdf') -CandidatePdf (Join-Path $TestDrive 'candidate-same-warning.pdf') -QpdfExe $fake -PdfInfoExe 'unused' -SafetyMode Safe
        $result.accepted | Should -BeFalse
        $result.status | Should -Be 'rejected'
        $result.reasons | Should -Contain 'unclassified-qpdf-warning'
    }
}

Describe 'qpdf JSON version contract' {
    It 'marks an unsupported JSON version indeterminate instead of treating features as absent' {
        $json = '{"version":999,"future_key":true}'
        Mock Get-PdfQpdfJsonText { [pscustomobject]@{ state='available'; text=$json; reason='qpdf-json-ok' } }
        $result = Get-PdfFeatures -PdfPath (Join-Path $TestDrive 'input.pdf') -QpdfExe 'unused'
        $result.detector_version | Should -Be '999'
        $result.warnings | Should -Contain 'qpdf-json-version-unknown'
        $result.features.acroform.state | Should -Be 'indeterminate'
    }

    It 'accepts the current JSON version and ignores unknown keys' {
        $json = '{"version":2,"future_key":true,"acroform":{"hasacroform":false}}'
        Mock Get-PdfQpdfJsonText { [pscustomobject]@{ state='available'; text=$json; reason='qpdf-json-ok' } }
        $result = Get-PdfFeatures -PdfPath (Join-Path $TestDrive 'input.pdf') -QpdfExe 'unused'
        $result.detector_version | Should -Be '2'
        $result.warnings | Should -Not -Contain 'qpdf-json-version-unknown'
        $result.features.acroform.state | Should -Be 'absent'
    }
}

Describe 'structure comparison and normalization contract' {
    It 'rejects missing or extra pages' {
        $before = New-TestSnapshot -PageCount 2 -Pages @(
            [pscustomobject]@{ media_box=@(0,0,612,792); crop_box=@(0,0,612,792); rotate=0 },
            [pscustomobject]@{ media_box=@(0,0,612,792); crop_box=@(0,0,612,792); rotate=0 }
        )
        $after = New-TestSnapshot -PageCount 1
        $result = Compare-PdfStructureSnapshot -Before $before -After $after
        $result.equal | Should -BeFalse
        $result.reasons | Should -Contain 'page-count-mismatch'
    }

    It 'normalizes an undefined CropBox to MediaBox and parses decimal values invariantly' {
        $pdfinfo = Join-Path $TestDrive 'pdfinfo.ps1'
        @'
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)
Write-Output 'Pages:           1'
Write-Output 'Page 1 MediaBox: 0.00 0.00 612.00 792.00'
Write-Output 'Page 1 rot: 0'
exit 0
'@ | Set-Content -LiteralPath $pdfinfo -Encoding UTF8
        $pdf = Join-Path $TestDrive 'input.pdf'
        Set-Content -LiteralPath $pdf -Value '%PDF-1.4' -Encoding ascii
        $snapshot = Get-PdfStructureSnapshot -PdfPath $pdf -PdfInfoExe $pdfinfo
        $snapshot.status | Should -Be 'verified'
        (Compare-PdfStructureSnapshot -Before $snapshot -After $snapshot).equal | Should -BeTrue
        $snapshot.pages[0].crop_box | Should -Be @(0,0,612,792)
    }

    It 'rejects MediaBox, CropBox and Rotate differences independently' {
        $before = New-TestSnapshot
        $after = New-TestSnapshot -Pages @([pscustomobject]@{ media_box=@(0,0,600,792); crop_box=@(0,0,612,780); rotate=90 })
        $result = Compare-PdfStructureSnapshot -Before $before -After $after
        $result.reasons | Should -Contain 'media-box-mismatch'
        $result.reasons | Should -Contain 'crop-box-mismatch'
        $result.reasons | Should -Contain 'rotate-mismatch'
    }

    It 'accepts only a caller-bounded device-pixel box delta for raster output' {
        $before = New-TestSnapshot -Pages @([pscustomobject]@{ media_box=@(0,0,595.32,841.92); crop_box=@(0,0,595.32,841.92); rotate=0 })
        $rounded = New-TestSnapshot -Pages @([pscustomobject]@{ media_box=@(0,0,595.20,841.80); crop_box=@(0,0,595.20,841.80); rotate=0 })
        (Compare-PdfStructureSnapshot -Before $before -After $rounded).equal | Should -BeFalse
        (Compare-PdfStructureSnapshot -Before $before -After $rounded -Tolerance 0.6).equal | Should -BeTrue

        $cropped = New-TestSnapshot -Pages @([pscustomobject]@{ media_box=@(0,0,595.20,841.80); crop_box=@(18,24,577,817); rotate=0 })
        $result = Compare-PdfStructureSnapshot -Before $before -After $cropped -Tolerance 0.6
        $result.equal | Should -BeFalse
        $result.reasons | Should -Contain 'crop-box-mismatch'
    }
}
