Set-StrictMode -Version Latest

BeforeAll {
    $internalRoot = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internalRoot 'diagnostic-messages.ps1')
    $script:dataPath = Join-Path $internalRoot 'data\diagnostic-messages.json'
}

Describe 'shared diagnostic message lookup' {
    It 'resolves the same reason code for the CLI and GUI data source' {
        $cliMessage = Get-DiagnosticMessage -Code 'qpdf-unavailable' -Path $script:dataPath
        $guiData = Get-Content -LiteralPath $script:dataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $guiMessage = Get-DiagnosticMessage -Code 'qpdf-unavailable' -Data $guiData
        $cliMessage | Should -Be $guiMessage
        $cliMessage | Should -Not -Be 'qpdf-unavailable'
    }

    It 'returns a stable code for an unknown reason without throwing' {
        { Get-DiagnosticMessage -Code 'unknown-diagnostic-code' -Path $script:dataPath } | Should -Not -Throw
        (Get-DiagnosticMessage -Code 'unknown-diagnostic-code' -Path $script:dataPath) | Should -Be 'unknown-diagnostic-code'
    }


    It 'provides actionable messages for structural validation failures' {
        foreach ($code in @('media-box-mismatch','crop-box-mismatch','rotate-mismatch','page-count-mismatch')) {
            Get-DiagnosticMessage -Code $code -Path $script:dataPath | Should -Not -Be $code
        }
    }
}
