BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'select_strategy.ps1')
    $script:CfgPath = Join-Path $PSScriptRoot '..\..\_internal' 'data' 'strategies.json'
    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "pdfcomp-dpi-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:TmpDir) {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'select_strategy.ps1 rejects malformed DPI in strategies.json' {
    It 'rejects DPI > 600' {
        $bad = @{
            version = '1.0'
            allowed_dpi = @(150)
            thresholds = @{ image_ratio_low = 0.3; image_ratio_high = 0.7; dpi_high = 220 }
            strategies = @(
                @{ strategy_id = 'gs-downsample-150'; tool = 'ghostscript'; params = @{ color_dpi = 9999; gray_dpi = 9999 } }
            )
        } | ConvertTo-Json -Depth 6
        $path = Join-Path $script:TmpDir 'bad-high.json'
        Set-Content -LiteralPath $path -Value $bad -Encoding UTF8
        $m = [pscustomobject]@{ imageRatio = 0.85; hasImages = $true; avgDpi = 300 }
        { Select-CompressionStrategy -Metrics $m -ConfigPath $path } | Should -Throw
    }

    It 'rejects DPI not in whitelist' {
        $bad = @{
            version = '1.0'
            allowed_dpi = @(72,96,120,150,180,220,300)
            thresholds = @{ image_ratio_low = 0.3; image_ratio_high = 0.7; dpi_high = 220 }
            strategies = @(
                @{ strategy_id = 'gs-downsample-150'; tool = 'ghostscript'; params = @{ color_dpi = 200; gray_dpi = 200 } }
            )
        } | ConvertTo-Json -Depth 6
        $path = Join-Path $script:TmpDir 'bad-whitelist.json'
        Set-Content -LiteralPath $path -Value $bad -Encoding UTF8
        $m = [pscustomobject]@{ imageRatio = 0.85; hasImages = $true; avgDpi = 300 }
        { Select-CompressionStrategy -Metrics $m -ConfigPath $path } | Should -Throw
    }

    It 'accepts default strategies.json' {
        $m = [pscustomobject]@{ imageRatio = 0.85; hasImages = $true; avgDpi = 300 }
        { Select-CompressionStrategy -Metrics $m -ConfigPath $script:CfgPath } | Should -Not -Throw
    }

    It 'rejects lossy raster DPI above its independent schema range' {
        $bad = @'
{
  "version": "1.0",
  "allowed_dpi": [72, 96, 120, 150, 180, 220, 300],
  "thresholds": { "image_ratio_low": 0.3, "image_ratio_high": 0.7, "dpi_high": 220 },
  "strategies": [
    { "strategy_id": "gs-raster-low-quality", "tool": "lossy-raster", "params": { "raster_dpi": 301, "jpeg_quality": 45 }, "fallback": null }
  ]
}
'@
        $path = Join-Path $script:TmpDir 'bad-raster-dpi.json'
        Set-Content -LiteralPath $path -Value $bad -Encoding UTF8
        { Get-Strategies -JsonPath $path } | Should -Throw
    }

    It 'rejects lossy raster JPEG quality outside 1..100' {
        $bad = @'
{
  "version": "1.0",
  "allowed_dpi": [72, 96, 120, 150, 180, 220, 300],
  "thresholds": { "image_ratio_low": 0.3, "image_ratio_high": 0.7, "dpi_high": 220 },
  "strategies": [
    { "strategy_id": "gs-raster-low-quality", "tool": "lossy-raster", "params": { "raster_dpi": 120, "jpeg_quality": 101 }, "fallback": null }
  ]
}
'@
        $path = Join-Path $script:TmpDir 'bad-jpeg-quality.json'
        Set-Content -LiteralPath $path -Value $bad -Encoding UTF8
        { Get-Strategies -JsonPath $path } | Should -Throw
    }
}

Describe 'select_strategy.ps1 schema/Test-Json availability is mandatory' {
    It 'throws when schema file is missing alongside strategies.json' {
        $stratDir = Join-Path $script:TmpDir 'no-schema'
        New-Item -ItemType Directory -Path $stratDir -Force | Out-Null
        $stratPath = Join-Path $stratDir 'strategies.json'
        $body = @{
            version = '1.0'
            allowed_dpi = @(150)
            thresholds = @{ image_ratio_low = 0.3; image_ratio_high = 0.7; dpi_high = 220 }
            strategies = @(
                @{ strategy_id = 'qpdf-lossless'; tool = 'qpdf'; params = @{} }
            )
        } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $stratPath -Value $body -Encoding UTF8
        { Get-Strategies -JsonPath $stratPath } |
            Should -Throw -ExpectedMessage '*schema file not found*'
    }

    It 'select_strategy.ps1 source contains Test-Json availability guard' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\_internal' 'select_strategy.ps1')
        $src | Should -Match 'Get-Command\s+Test-Json'
        $src | Should -Match 'PowerShell 7\+ \(pwsh\) is required'
    }

    It 'throws when schema is present but malformed JSON (Test-Json validation fail)' {
        $stratDir = Join-Path $script:TmpDir 'bad-schema-content'
        New-Item -ItemType Directory -Path $stratDir -Force | Out-Null
        $stratPath  = Join-Path $stratDir 'strategies.json'
        $schemaPath = Join-Path $stratDir 'strategies.schema.json'
        $body = @{
            version = '1.0'
            allowed_dpi = @(150)
            thresholds = @{ image_ratio_low = 0.3; image_ratio_high = 0.7; dpi_high = 220 }
            strategies = @(@{ strategy_id = 'qpdf-lossless'; tool = 'qpdf'; params = @{} })
        } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $stratPath -Value $body -Encoding UTF8
        # strategy_id を許容しない厳しい schema を投入
        $schema = '{"type":"object","required":["version"],"properties":{"strategies":{"type":"array","items":{"type":"object","required":["forbidden_key"]}}}}'
        Set-Content -LiteralPath $schemaPath -Value $schema -Encoding UTF8
        { Get-Strategies -JsonPath $stratPath } | Should -Throw
    }
}
