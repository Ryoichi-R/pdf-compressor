BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'analyze_pdf.ps1')
}

Describe 'Convert-SizeToBytes' {
    It 'plain bytes (no suffix)' {
        (Convert-SizeToBytes -Raw '12345').bytes | Should -Be 12345
    }
    It 'B suffix' {
        (Convert-SizeToBytes -Raw '100B').bytes | Should -Be 100
    }
    It 'K suffix = 1024' {
        (Convert-SizeToBytes -Raw '2K').bytes | Should -Be 2048
    }
    It 'KB suffix = 1024' {
        (Convert-SizeToBytes -Raw '3KB').bytes | Should -Be 3072
    }
    It 'KiB suffix = 1024' {
        (Convert-SizeToBytes -Raw '1KiB').bytes | Should -Be 1024
    }
    It 'M and MB and MiB equal 1024^2' {
        (Convert-SizeToBytes -Raw '1M').bytes  | Should -Be 1048576
        (Convert-SizeToBytes -Raw '1MB').bytes | Should -Be 1048576
        (Convert-SizeToBytes -Raw '1MiB').bytes| Should -Be 1048576
    }
    It 'dash returns 0 with warn' {
        $r = Convert-SizeToBytes -Raw '-'
        $r.bytes | Should -Be 0
        $r.warn  | Should -BeTrue
    }
    It 'garbage returns 0 with warn' {
        $r = Convert-SizeToBytes -Raw 'abc'
        $r.bytes | Should -Be 0
        $r.warn  | Should -BeTrue
    }
    It 'decimal MB' {
        (Convert-SizeToBytes -Raw '1.5M').bytes | Should -Be ([long](1.5 * 1048576))
    }
}

Describe 'ConvertFrom-PdfImagesList' {
    It 'parses header + sample rows with mixed suffixes' {
        $lines = @(
            'page   num  type   width height color comp bpc  enc interp  object ID x-ppi y-ppi size ratio'
            '--------------------------------------------------------------------------------------------'
            '   1     0 image    1654  2339  rgb     3   8  jpeg   no       12  0   150   150 524288 12.5%'
            '   1     1 smask    1654  2339  gray    1   8  image  no       13  0   150   150 100K 5.0%'
            '   2     2 image     800  1000  gray    1   1  ccitt  no       14  0   200   200 32KiB 8.0%'
            '   3     3 image     800  1000  rgb     3   8  jpeg   no       15  0     -     - 200 4.0%'
        )
        $recs = ConvertFrom-PdfImagesList -Lines $lines
        $recs.Count | Should -Be 4
        $recs[0].type | Should -Be 'image'
        $recs[1].type | Should -Be 'smask'
        $recs[2].sizeRaw | Should -Be '32KiB'
        $recs[3].xppi | Should -Be '-'
    }
}
