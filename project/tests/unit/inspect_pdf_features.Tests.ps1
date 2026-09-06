Set-StrictMode -Version Latest

BeforeAll {
    $internalRoot = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internalRoot 'tool-resolver.ps1')
    . (Join-Path $internalRoot 'inspect_pdf_features.ps1')
    $script:qpdf = Find-ToolExecutable -Name 'qpdf'
    $script:fixture = Join-Path $PSScriptRoot '..\fixtures\pdf\minimal-text.pdf'
}

Describe 'qpdf JSON feature detector' -Tag 'ExternalTool' {
    It 'does not report empty qpdf v2 containers as present' {
        if (-not $script:qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $features = Get-PdfFeatures -PdfPath $script:fixture -QpdfExe $script:qpdf
        $features.features['acroform'].state | Should -Be 'absent'
        $features.features['attachments'].state | Should -Be 'absent'
        $features.features['outlines'].state | Should -Be 'absent'
    }

    It 'bounds qpdf JSON before parsing oversized output' {
        if (-not $script:qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $result = Get-PdfQpdfJsonText -QpdfExe $script:qpdf -PdfPath $script:fixture -MaxBytes 1
        $result.state | Should -Be 'indeterminate'
        $result.reason | Should -Be 'qpdf-json-limit-exceeded'
        $result.text | Should -BeNullOrEmpty
    }
}
