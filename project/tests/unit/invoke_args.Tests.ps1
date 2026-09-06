BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_ghostscript.ps1')
    . (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_qpdf.ps1')
}

Describe 'Invoke-Ghostscript argument construction' {
    BeforeAll {
        $script:AllowedDpi = @(72, 96, 120, 150, 180, 220, 300)
    }
    It 'rejects DPI out of range (color)' {
        { Invoke-Ghostscript -GhostscriptExe 'C:\nonexistent.exe' -InputPdf 'C:\nope.pdf' -OutputPdf 'C:\out.pdf' -ColorDpi 50 -GrayDpi 150 -AllowedDpi $script:AllowedDpi } | Should -Throw
    }
    It 'rejects DPI out of range (gray)' {
        { Invoke-Ghostscript -GhostscriptExe 'C:\nonexistent.exe' -InputPdf 'C:\nope.pdf' -OutputPdf 'C:\out.pdf' -ColorDpi 150 -GrayDpi 9999 -AllowedDpi $script:AllowedDpi } | Should -Throw
    }
    It 'rejects DPI inside range but missing from -AllowedDpi (SSoT enforcement)' {
        # 200 is in 72..600 but not in the canonical strategies.json whitelist.
        { Invoke-Ghostscript -GhostscriptExe 'C:\nonexistent.exe' -InputPdf 'C:\nope.pdf' -OutputPdf 'C:\out.pdf' -ColorDpi 200 -GrayDpi 150 -AllowedDpi $script:AllowedDpi } | Should -Throw
    }
    It 'requires -AllowedDpi (parameter is mandatory)' {
        { Invoke-Ghostscript -GhostscriptExe 'C:\nonexistent.exe' -InputPdf 'C:\nope.pdf' -OutputPdf 'C:\out.pdf' -ColorDpi 150 -GrayDpi 150 } | Should -Throw
    }
    It 'reports missing executable without throwing' {
        $r = Invoke-Ghostscript -GhostscriptExe 'C:\nonexistent-ghostscript.exe' -InputPdf 'C:\nope.pdf' -OutputPdf 'C:\out.pdf' -ColorDpi 150 -GrayDpi 150 -AllowedDpi $script:AllowedDpi
        $r.success | Should -BeFalse
        $r.tool | Should -Be 'ghostscript'
    }
}

Describe 'Invoke-Qpdf argument construction' {
    It 'reports missing executable without throwing' {
        $r = Invoke-Qpdf -QpdfExe 'C:\nonexistent-qpdf.exe' -InputPdf 'C:\nope.pdf' -OutputPdf 'C:\out.pdf'
        $r.success | Should -BeFalse
        $r.tool | Should -Be 'qpdf'
    }
}

Describe 'source code: DPI whitelist SSoT (P1-4)' {
    It 'invoke_ghostscript.ps1 no longer hardcodes the DPI whitelist' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_ghostscript.ps1')
        $code | Should -Not -Match '@\(72,\s*96,\s*120,\s*150,\s*180,\s*220,\s*300\)'
        $code | Should -Match '\[int\[\]\]\$AllowedDpi'
    }
    It 'compress.ps1 sources allowed_dpi from the loaded Strategies object' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $code | Should -Match '\$Strategies\.allowed_dpi'
        $code | Should -Match '-AllowedDpi\s+\$allowedDpi'
    }
}

Describe 'source code: no string interpolation of exec paths' {
    It 'no Invoke-Expression in invoke_ghostscript.ps1' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_ghostscript.ps1')
        $code | Should -Not -Match 'Invoke-Expression'
        $code | Should -Not -Match 'iex\b'
    }
    It 'no Invoke-Expression in invoke_qpdf.ps1' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_qpdf.ps1')
        $code | Should -Not -Match 'Invoke-Expression'
        $code | Should -Not -Match 'iex\b'
    }
    It 'no cmd /c invocation in invoke scripts' {
        $g = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_ghostscript.ps1')
        $q = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_qpdf.ps1')
        ($g + $q) | Should -Not -Match 'cmd\s+/c'
    }
}
