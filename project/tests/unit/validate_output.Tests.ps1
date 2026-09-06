Set-StrictMode -Version Latest

BeforeAll {
    $internalRoot = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internalRoot 'tool-resolver.ps1')
    . (Join-Path $internalRoot 'pdf-structure.ps1')
    . (Join-Path $internalRoot 'validate_output.ps1')
    $script:qpdf = Find-ToolExecutable -Name 'qpdf'
    $script:fixture = Join-Path $PSScriptRoot '..\fixtures\pdf\minimal-text.pdf'
}

Describe 'Validate-CompressedPdf' -Tag 'ExternalTool' {
    It 'accepts a valid unchanged candidate after qpdf check' {
        if (-not $script:qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $before = [pscustomobject]@{ status = 'verified'; page_count = 1; pages = @([pscustomobject]@{ media_box = @(0,0,612,792); crop_box = @(0,0,612,792); rotate = 0 }) }
        $after = [pscustomobject]@{ status = 'verified'; page_count = 1; pages = @([pscustomobject]@{ media_box = @(0,0,612,792); crop_box = @(0,0,612,792); rotate = 0 }) }
        $result = Validate-CompressedPdf -InputPdf $script:fixture -CandidatePdf $script:fixture -QpdfExe $script:qpdf -PdfInfoExe 'unused' -BeforeStructure $before -AfterStructure $after -SafetyMode Safe
        $result.accepted | Should -BeTrue
        $result.status | Should -Be 'verified'
        $result.reasons | Should -BeNullOrEmpty
    }

    It 'rejects an invalid candidate PDF' {
        if (-not $script:qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $candidate = Join-Path $TestDrive 'invalid.pdf'
        Set-Content -LiteralPath $candidate -Value 'not a PDF' -Encoding ascii
        $result = Validate-CompressedPdf -InputPdf $script:fixture -CandidatePdf $candidate -QpdfExe $script:qpdf -PdfInfoExe 'unused' -SafetyMode Safe
        $result.accepted | Should -BeFalse
        $result.status | Should -BeIn @('rejected','tool-failure')
        $result.reasons | Should -Match 'qpdf-output-'
    }

    It 'uses data policy to reject Safe loss of preserve features' {
        if (-not $script:qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $before = [pscustomobject]@{ status = 'verified'; page_count = 1; pages = @([pscustomobject]@{ media_box = @(0,0,612,792); crop_box = @(0,0,612,792); rotate = 0 }) }
        $after = $before
        $beforeFeatures = [pscustomobject]@{ features = [pscustomobject]@{ attachments = [pscustomobject]@{ state = 'present' } } }
        $afterFeatures = [pscustomobject]@{ features = [pscustomobject]@{ attachments = [pscustomobject]@{ state = 'absent' } } }
        $result = Validate-CompressedPdf -InputPdf $script:fixture -CandidatePdf $script:fixture -QpdfExe $script:qpdf -PdfInfoExe 'unused' -BeforeStructure $before -AfterStructure $after -BeforeFeatures $beforeFeatures -AfterFeatures $afterFeatures -SafetyMode Safe
        $result.accepted | Should -BeFalse
        $result.status | Should -Be 'rejected'
        $result.reasons | Should -Contain 'feature-loss:attachments'
    }

    It 'records Off-mode feature loss without rejecting the candidate' {
        if (-not $script:qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $before = [pscustomobject]@{ status = 'verified'; page_count = 1; pages = @([pscustomobject]@{ media_box = @(0,0,612,792); crop_box = @(0,0,612,792); rotate = 0 }) }
        $after = $before
        $beforeFeatures = [pscustomobject]@{ features = [pscustomobject]@{ attachments = [pscustomobject]@{ state = 'present' } } }
        $afterFeatures = [pscustomobject]@{ features = [pscustomobject]@{ attachments = [pscustomobject]@{ state = 'absent' } } }
        $result = Validate-CompressedPdf -InputPdf $script:fixture -CandidatePdf $script:fixture -QpdfExe $script:qpdf -PdfInfoExe 'unused' -BeforeStructure $before -AfterStructure $after -BeforeFeatures $beforeFeatures -AfterFeatures $afterFeatures -SafetyMode Off
        $result.accepted | Should -BeTrue
        $result.status | Should -Be 'verified'
        $result.reasons | Should -Contain 'feature-loss-recorded:attachments'
    }
}
