BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:buildScript = Join-Path $projectRoot 'installer\dependencies\Build-PopplerArm64.ps1'
    $script:source = Get-Content -LiteralPath $script:buildScript -Raw
}

Describe 'Poppler ARM64 source-build contract' {
    It 'pins the signature-verified official source archive digest' {
        $script:source | Should -Match '304832F48F8A47FDCA90C6B6D1F684E68F37C10C9A0726F345F4CA9DF4CA01E2'
        $script:source | Should -Match 'Get-FileHash.+SHA256'
    }

    It 'requires native ARM64 and a short workspace build root' {
        $script:source | Should -Match 'OSArchitecture.+Arm64'
        $script:source | Should -Match 'ProcessArchitecture.+Arm64'
        $script:source | Should -Match 'HostARM64\\arm64\\cl\.exe'
        $script:source | Should -Match 'BuildRoot is too long'
        $script:source | Should -Match 'Refusing to overwrite existing output'
    }

    It 'uses the validated minimal utility build without source patches' {
        $script:source | Should -Match "'-DCMAKE_CXX_FLAGS=/utf-8 /EHsc'"
        $script:source | Should -Match "'-DENABLE_UTILS=ON'"
        $script:source | Should -Match "'-DENABLE_QT6=OFF'"
        $script:source | Should -Match "patches = @\(\)"
        $script:source | Should -Match "'openjpeg:arm64-windows'"
    }

    It 'stages an ARM64 runtime closure and validates every product utility' {
        $script:source | Should -Match '0xAA64'
        $script:source | Should -Match "@\('pdfinfo\.exe', 'pdfimages\.exe', 'pdftoppm\.exe', 'pdfdetach\.exe', 'poppler\.dll'\)"
        $script:source | Should -Match "'msvcp140\.dll', 'vcruntime140\.dll'"
        $script:source | Should -Match 'minimal-text\.pdf'
        $script:source | Should -Match '-singlefile -png'
    }
}
