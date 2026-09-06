BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:buildScript = Join-Path $projectRoot 'installer\dependencies\Build-GhostscriptArm64.ps1'
    $script:source = Get-Content -LiteralPath $script:buildScript -Raw
}

Describe 'Ghostscript ARM64 source-build contract' {
    It 'pins the adopted official source archive digest' {
        $script:source | Should -Match '1CDB766DE8DB8F1E589C817F09C5855EA5F65DFC8540E465A69AC14C18416025'
        $script:source | Should -Match 'Get-FileHash.+SHA256'
    }

    It 'requires native ARM64 host and ARM64 MSVC tools' {
        $script:source | Should -Match 'OSArchitecture.+Arm64'
        $script:source | Should -Match 'ProcessArchitecture.+Arm64'
        $script:source | Should -Match 'HostARM64\\arm64\\nmake\.exe'
        $script:source | Should -Match 'VC\.Tools\.ARM64'
    }

    It 'disables x86-only acceleration and unused OCR without source patches' {
        $script:source | Should -Match "'DONT_HAVE_SSE2=1'"
        $script:source | Should -Match "'OCR_VERSION=0'"
        $script:source | Should -Match "patches = @\(\)"
    }

    It 'verifies PE architecture, required devices, PDF regeneration, and runtime closure' {
        $script:source | Should -Match '0xAA64'
        $script:source | Should -Match "@\('pdfwrite', 'pdfimage24'\)"
        $script:source | Should -Match 'minimal-text\.pdf'
        $script:source | Should -Match 'vcruntime140\.dll'
        $script:source | Should -Match 'Refusing to overwrite existing output'
    }
}
