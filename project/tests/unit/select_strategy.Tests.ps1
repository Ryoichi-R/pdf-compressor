BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'select_strategy.ps1')
    $script:CfgPath = Join-Path $PSScriptRoot '..\..\_internal' 'data' 'strategies.json'
}

Describe 'Select-CompressionStrategy' {
    It 'text-dominant (no images) -> qpdf-lossless' {
        $m = [pscustomobject]@{
            imageRatio = 0.0; hasImages = $false; avgDpi = $null
        }
        (Select-CompressionStrategy -Metrics $m -ConfigPath $script:CfgPath).strategy_id | Should -Be 'qpdf-lossless'
    }
    It 'low image ratio (0.2) -> qpdf-lossless' {
        $m = [pscustomobject]@{ imageRatio = 0.2; hasImages = $true; avgDpi = 150 }
        (Select-CompressionStrategy -Metrics $m -ConfigPath $script:CfgPath).strategy_id | Should -Be 'qpdf-lossless'
    }
    It 'high image ratio + high DPI -> gs-downsample-150' {
        $m = [pscustomobject]@{ imageRatio = 0.85; hasImages = $true; avgDpi = 300 }
        (Select-CompressionStrategy -Metrics $m -ConfigPath $script:CfgPath).strategy_id | Should -Be 'gs-downsample-150'
    }
    It 'high image ratio + low DPI -> qpdf-lossless with gs-light-regenerate fallback' {
        $m = [pscustomobject]@{ imageRatio = 0.85; hasImages = $true; avgDpi = 120 }
        $r = Select-CompressionStrategy -Metrics $m -ConfigPath $script:CfgPath
        $r.strategy_id | Should -Be 'qpdf-lossless'
        $r.fallback    | Should -Be 'gs-light-regenerate'
    }
    It 'mixed content (0.5) -> gs-downsample-180' {
        $m = [pscustomobject]@{ imageRatio = 0.5; hasImages = $true; avgDpi = 150 }
        (Select-CompressionStrategy -Metrics $m -ConfigPath $script:CfgPath).strategy_id | Should -Be 'gs-downsample-180'
    }
    It 'auto selection never chooses the lossy raster strategy' {
        $cases = @(
            [pscustomobject]@{ imageRatio = 0.0; hasImages = $false; avgDpi = $null },
            [pscustomobject]@{ imageRatio = 0.2; hasImages = $true; avgDpi = 150 },
            [pscustomobject]@{ imageRatio = 0.5; hasImages = $true; avgDpi = 150 },
            [pscustomobject]@{ imageRatio = 0.85; hasImages = $true; avgDpi = 300 },
            [pscustomobject]@{ imageRatio = 0.85; hasImages = $true; avgDpi = 120 }
        )
        foreach ($m in $cases) {
            (Select-CompressionStrategy -Metrics $m -ConfigPath $script:CfgPath).strategy_id | Should -Not -Be 'gs-raster-low-quality'
            (Select-CompressionStrategy -Metrics $m -ConfigPath $script:CfgPath).strategy_id | Should -Not -Be 'gs-raster-readable'
        }
    }
}

Describe 'Assert-DpiAllowed' {
    It 'accepts whitelisted dpi' {
        { Assert-DpiAllowed -Dpi 150 -Allowed @(72,96,120,150,180,220,300) } | Should -Not -Throw
    }
    It 'rejects out-of-range' {
        { Assert-DpiAllowed -Dpi 50 -Allowed @(150,180) } | Should -Throw
        { Assert-DpiAllowed -Dpi 9999 -Allowed @(150,180) } | Should -Throw
    }
    It 'rejects in-range but non-whitelisted' {
        { Assert-DpiAllowed -Dpi 200 -Allowed @(72,96,120,150,180,220,300) } | Should -Throw
    }
}
