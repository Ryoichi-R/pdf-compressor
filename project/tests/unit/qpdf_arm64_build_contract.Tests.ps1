BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:buildScript = Join-Path $projectRoot 'installer\dependencies\Build-QpdfArm64.ps1'
    $script:source = Get-Content -LiteralPath $script:buildScript -Raw
}

Describe 'qpdf ARM64 source-build contract' {
    It 'pins the adopted official source archive digest' {
        $script:source | Should -Match '6CBA2F9F2CD887D905FAEB99E0E51A307B217920D1BBF3E9CFBB2E8178A2DEDA'
        $script:source | Should -Match 'Get-FileHash.+SHA256'
    }

    It 'requires native ARM64 and a short workspace build root' {
        $script:source | Should -Match 'OSArchitecture.+Arm64'
        $script:source | Should -Match 'ProcessArchitecture.+Arm64'
        $script:source | Should -Match 'HostARM64\\arm64\\cl\.exe'
        $script:source | Should -Match 'BuildRoot is too long'
        $script:source | Should -Match 'Refusing to overwrite existing output'
    }

    It 'uses the validated MSVC Ninja configuration without source patches' {
        $script:source | Should -Match "'-DCMAKE_CXX_FLAGS=/utf-8 /EHsc'"
        $script:source | Should -Match "'-DREQUIRE_CRYPTO_NATIVE=ON'"
        $script:source | Should -Match "patches = @\(\)"
        $script:source | Should -Match "'zlib:arm64-windows'"
        $script:source | Should -Match "'libjpeg-turbo:arm64-windows'"
    }

    It 'stages an explicit ARM64 runtime closure and validates a PDF transformation' {
        $script:source | Should -Match '0xAA64'
        $script:source | Should -Match "'qpdf30\.dll'"
        $script:source | Should -Match "'jpeg62\.dll'"
        $script:source | Should -Match "'vcruntime140\.dll'"
        $script:source | Should -Match 'minimal-text\.pdf'
        $script:source | Should -Match '--object-streams=generate'
    }
}
