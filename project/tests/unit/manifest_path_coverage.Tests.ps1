BeforeAll {
    $internal = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internal 'path-guard.ps1')
    . (Join-Path $internal 'input-manifest.ps1')
    . (Join-Path $internal 'output-path.ps1')
}

Describe 'manifest directory and setting coverage' {
    It 'recursively enumerates PDFs and excludes generated compressed outputs' {
        $root = Join-Path $TestDrive 'inputs';$sub=Join-Path $root 'sub'
        [IO.Directory]::CreateDirectory($sub) | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'a.pdf') -Value '%PDF'
        Set-Content -LiteralPath (Join-Path $sub 'b.pdf') -Value '%PDF'
        Set-Content -LiteralPath (Join-Path $sub 'b.compressed.pdf') -Value '%PDF'
        Set-Content -LiteralPath (Join-Path $sub 'note.txt') -Value text
        $manifest = New-InputManifestFromPath -InputPath $root -Mode standard -SafetyMode Warn -TargetBytes 100 -EnableOcr -OcrLanguages eng -AllowSignedPdf -AllowFullPageRaster
        $manifest.items.Count | Should -Be 2
        $manifest.defaults.mode | Should -Be 'standard'
        $manifest.defaults.ocr.enabled | Should -BeTrue
        $manifest.items[0].allow_signed_pdf | Should -BeTrue
        @($manifest.items.input_path | Where-Object { $_ -like '*.compressed.pdf' }).Count | Should -Be 0
        Get-ManifestItemSetting ([pscustomobject]@{mode='high-quality'}) ([pscustomobject]@{mode='auto'}) mode | Should -Be 'high-quality'
    }
}

Describe 'output origin and relative path coverage' {
    # ドライブレターと UNC は Windows 固有の origin 識別子。
    It 'creates stable drive and UNC origin identifiers' -Tag 'WindowsOnly' {
        (Get-OutputOriginId ([IO.FileInfo]::new('C:\source\a.pdf'))) | Should -Match '^drive-c-'
        (Get-OutputOriginId ([IO.FileInfo]::new('\\server\share\folder\a.pdf'))) | Should -Match '^unc-'
    }

    It 'returns empty relative directory when the file is outside source root' {
        Get-OutputRelativeDirectory ([IO.FileInfo]::new('C:\other\a.pdf')) 'C:\source' | Should -Be ''
    }
}

Describe 'path guard boundary coverage' {
    It 'rejects empty, device, UNC, directory, and non-PDF inputs' {
        { Assert-InputPathReadable -InputPath '' } | Should -Throw
        { Assert-InputPathReadable -InputPath '\\?\C:\x.pdf' } | Should -Throw
        { Assert-InputPathReadable -InputPath '\\server\share\x.pdf' } | Should -Throw
        $dir=Join-Path $TestDrive dir;[IO.Directory]::CreateDirectory($dir)|Out-Null
        { Assert-InputPathReadable -InputPath $dir } | Should -Throw
        (Assert-InputPathReadable -InputPath $dir -AllowDirectory).kind | Should -Be 'directory'
        $txt=Join-Path $TestDrive a.txt;Set-Content -LiteralPath $txt -Value x
        { Assert-InputPathReadable -InputPath $txt } | Should -Throw
        Test-InputPathReadable -InputPath $txt | Should -BeFalse
    }

    It 'rejects empty, device, UNC, and relative output roots' {
        { Assert-OutputPathLocal -TargetPath '' } | Should -Throw
        foreach($value in @('\\?\C:\x', '\\server\share\x', 'relative\x')) {
            { Assert-OutputPathLocal -TargetPath $value } | Should -Throw
            Test-OutputPathLocal -TargetPath $value | Should -BeFalse
        }
    }
}
