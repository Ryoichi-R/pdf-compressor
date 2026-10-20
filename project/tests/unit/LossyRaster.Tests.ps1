BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_lossy_raster.ps1')
}

Describe 'Invoke-LossyRaster argument and validation behavior' {
    It 'rejects raster DPI outside the lossy raster range' {
        { Invoke-LossyRaster -GhostscriptExe 'C:\missing.exe' -InputPdf 'C:\in.pdf' -OutputPdf 'C:\out.pdf' -RasterDpi 50 -JpegQuality 45 } | Should -Throw
        { Invoke-LossyRaster -GhostscriptExe 'C:\missing.exe' -InputPdf 'C:\in.pdf' -OutputPdf 'C:\out.pdf' -RasterDpi 301 -JpegQuality 45 } | Should -Throw
    }

    It 'rejects JPEG quality outside 1..100' {
        { Invoke-LossyRaster -GhostscriptExe 'C:\missing.exe' -InputPdf 'C:\in.pdf' -OutputPdf 'C:\out.pdf' -RasterDpi 120 -JpegQuality 0 } | Should -Throw
        { Invoke-LossyRaster -GhostscriptExe 'C:\missing.exe' -InputPdf 'C:\in.pdf' -OutputPdf 'C:\out.pdf' -RasterDpi 120 -JpegQuality 101 } | Should -Throw
    }

    It 'reports missing executable without throwing after parameter validation' {
        $r = Invoke-LossyRaster -GhostscriptExe 'C:\missing-ghostscript.exe' -InputPdf 'C:\in.pdf' -OutputPdf 'C:\out.pdf' -RasterDpi 120 -JpegQuality 45
        $r.success | Should -BeFalse
        $r.tool | Should -Be 'lossy-raster'
    }
}

Describe 'source code: lossy raster command safety' {
    BeforeAll {
        $script:src = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\_internal' 'invoke_lossy_raster.ps1')
    }

    It 'uses Ghostscript pdfimage24 full-page rasterization' {
        $script:src | Should -Match "'-sDEVICE=pdfimage24'"
        $script:src | Should -Match '\(''-r'' \+ \$RasterDpi\)'
        $script:src | Should -Match '\(''-dJPEGQ='' \+ \$JpegQuality\)'
    }

    It 'does not use shell string execution' {
        $script:src | Should -Not -Match 'Invoke-Expression'
        $script:src | Should -Not -Match 'iex\b'
        $script:src | Should -Not -Match 'cmd\s+/c'
    }
}
