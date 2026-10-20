BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'gui-settings.ps1')
    $script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pdfcomp-gui-settings-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:tmpDir) {
        Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-DefaultGuiSettings' {
    It 'returns object with all required fields' {
        $d = Get-DefaultGuiSettings
        $d.version      | Should -Be '1.0'
        $d.lastInput    | Should -Be ''
        $d.outputRoot   | Should -Be ''
        $d.lastStrategy | Should -Be 'auto'
        $d.force        | Should -Be $false
        $d.windowSize.w | Should -Be 900
        $d.windowSize.h | Should -Be 700
        $d.windowPos.x  | Should -Be -1
        $d.windowPos.y  | Should -Be -1
    }
}

Describe 'Get-GuiSettings' {
    It 'returns defaults when file does not exist' {
        $p = Join-Path $script:tmpDir 'absent.json'
        $s = Get-GuiSettings -Path $p
        $s.version | Should -Be '1.0'
        $s.lastStrategy | Should -Be 'auto'
    }

    It 'merges loaded values onto defaults' {
        $p = Join-Path $script:tmpDir 'merge.json'
        @{
            version      = '1.0'
            lastInput    = 'C:\foo\bar.pdf'
            outputRoot   = 'D:\out'
            lastStrategy = 'gs-downsample-150'
            force        = $true
            windowSize   = @{ w = 1200; h = 800 }
            windowPos    = @{ x = 100;  y = 50 }
        } | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding UTF8
        $s = Get-GuiSettings -Path $p
        $s.lastInput    | Should -Be 'C:\foo\bar.pdf'
        $s.outputRoot   | Should -Be 'D:\out'
        $s.lastStrategy | Should -Be 'gs-downsample-150'
        $s.force        | Should -Be $true
        $s.windowSize.w | Should -Be 1200
        $s.windowPos.y  | Should -Be 50
    }

    It 'reverts unknown strategy to auto' {
        $p = Join-Path $script:tmpDir 'badstrat.json'
        @{ version = '1.0'; lastStrategy = 'super-magic' } | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding UTF8
        $s = Get-GuiSettings -Path $p
        $s.lastStrategy | Should -Be 'auto'
    }

    It 'accepts lossy raster strategy as a persisted lastStrategy' {
        $p = Join-Path $script:tmpDir 'lossy-strat.json'
        @{ version = '1.0'; lastStrategy = 'gs-raster-low-quality' } | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding UTF8
        $s = Get-GuiSettings -Path $p
        $s.lastStrategy | Should -Be 'gs-raster-low-quality'
    }

    It 'accepts readable raster strategy as a persisted lastStrategy' {
        $p = Join-Path $script:tmpDir 'readable-strat.json'
        @{ version = '1.0'; lastStrategy = 'gs-raster-readable' } | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding UTF8
        $s = Get-GuiSettings -Path $p
        $s.lastStrategy | Should -Be 'gs-raster-readable'
    }

    It 'reverts to defaults on version mismatch' {
        $p = Join-Path $script:tmpDir 'badver.json'
        @{ version = '99.0'; lastStrategy = 'qpdf-lossless' } | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding UTF8
        $s = Get-GuiSettings -Path $p -WarningAction SilentlyContinue
        $s.version      | Should -Be '1.0'
        $s.lastStrategy | Should -Be 'auto'
    }

    It 'reverts to defaults on JSON parse failure' {
        $p = Join-Path $script:tmpDir 'broken.json'
        Set-Content -LiteralPath $p -Value '{not json' -Encoding UTF8
        $s = Get-GuiSettings -Path $p -WarningAction SilentlyContinue
        $s.version | Should -Be '1.0'
    }

    It 'fills missing fields with defaults (forward compat)' {
        $p = Join-Path $script:tmpDir 'partial.json'
        @{ version = '1.0'; lastInput = 'C:\x.pdf' } | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding UTF8
        $s = Get-GuiSettings -Path $p
        $s.lastInput    | Should -Be 'C:\x.pdf'
        $s.outputRoot   | Should -Be ''
        $s.windowSize.w | Should -Be 900
    }
}

Describe 'Save-GuiSettings' {
    It 'writes JSON atomically and round-trips' {
        $p = Join-Path $script:tmpDir 'roundtrip.json'
        $s = Get-DefaultGuiSettings
        $s.lastInput  = 'C:\trip\in.pdf'
        $s.outputRoot = 'D:\trip\out'
        $s.force      = $true
        Save-GuiSettings -Settings $s -Path $p
        Test-Path -LiteralPath $p | Should -BeTrue
        $loaded = Get-GuiSettings -Path $p
        $loaded.lastInput  | Should -Be 'C:\trip\in.pdf'
        $loaded.outputRoot | Should -Be 'D:\trip\out'
        $loaded.force      | Should -Be $true
    }

    It 'creates parent directory when missing' {
        $sub = Join-Path $script:tmpDir 'nested\deeper\settings.json'
        $s = Get-DefaultGuiSettings
        Save-GuiSettings -Settings $s -Path $sub
        Test-Path -LiteralPath $sub | Should -BeTrue
    }
}
