BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'select_strategy.ps1')

    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "pdfcomp-fallback-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\_internal' 'data' 'strategies.schema.json') `
              -Destination (Join-Path $script:TmpDir 'strategies.schema.json') -Force

    function Write-StrategiesJson {
        param([Parameter(Mandatory)][string]$Body)
        $path = Join-Path $script:TmpDir 'strategies.json'
        Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
        return $path
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:TmpDir) {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'P1-6: fallback semantic validation in Get-Strategies' {
    It 'accepts a strategies.json with a valid fallback reference (the shipped file)' {
        $shipped = Join-Path $PSScriptRoot '..\..\_internal' 'data' 'strategies.json'
        { Get-Strategies -JsonPath $shipped } | Should -Not -Throw
    }

    It 'throws when a strategy declares a fallback referencing a missing strategy_id' {
        $body = @'
{
  "version": "1.0",
  "allowed_dpi": [72, 96, 120, 150, 180, 220, 300],
  "thresholds": { "image_ratio_low": 0.3, "image_ratio_high": 0.7, "dpi_high": 220 },
  "strategies": [
    { "strategy_id": "qpdf-lossless", "tool": "qpdf", "params": {}, "fallback": "gs-downsample-180" },
    { "strategy_id": "gs-light-regenerate", "tool": "ghostscript", "params": { "color_dpi": 220, "gray_dpi": 220 }, "fallback": null }
  ]
}
'@
        $path = Write-StrategiesJson -Body $body
        { Get-Strategies -JsonPath $path } | Should -Throw -ExpectedMessage '*not defined in strategies.json*'
    }

    It 'throws on a fallback cycle (A -> B -> A)' {
        $body = @'
{
  "version": "1.0",
  "allowed_dpi": [72, 96, 120, 150, 180, 220, 300],
  "thresholds": { "image_ratio_low": 0.3, "image_ratio_high": 0.7, "dpi_high": 220 },
  "strategies": [
    { "strategy_id": "qpdf-lossless", "tool": "qpdf", "params": {}, "fallback": "gs-light-regenerate" },
    { "strategy_id": "gs-light-regenerate", "tool": "ghostscript", "params": { "color_dpi": 220, "gray_dpi": 220 }, "fallback": "qpdf-lossless" }
  ]
}
'@
        $path = Write-StrategiesJson -Body $body
        { Get-Strategies -JsonPath $path } | Should -Throw -ExpectedMessage '*cycle detected*'
    }

    It 'accepts strategies that omit the fallback field entirely (schema makes it optional)' {
        $body = @'
{
  "version": "1.0",
  "allowed_dpi": [72, 96, 120, 150, 180, 220, 300],
  "thresholds": { "image_ratio_low": 0.3, "image_ratio_high": 0.7, "dpi_high": 220 },
  "strategies": [
    { "strategy_id": "qpdf-lossless", "tool": "qpdf", "params": {} }
  ]
}
'@
        $path = Write-StrategiesJson -Body $body
        { Get-Strategies -JsonPath $path } | Should -Not -Throw
    }

    It 'accepts lossy raster strategies with null fallback' {
        $body = @'
{
  "version": "1.0",
  "allowed_dpi": [72, 96, 120, 150, 180, 220, 300],
  "thresholds": { "image_ratio_low": 0.3, "image_ratio_high": 0.7, "dpi_high": 220 },
  "strategies": [
    { "strategy_id": "gs-raster-low-quality", "tool": "lossy-raster", "params": { "raster_dpi": 120, "jpeg_quality": 45 }, "fallback": null },
    { "strategy_id": "gs-raster-readable", "tool": "lossy-raster", "params": { "raster_dpi": 220, "jpeg_quality": 80 }, "fallback": null }
  ]
}
'@
        $path = Write-StrategiesJson -Body $body
        { Get-Strategies -JsonPath $path } | Should -Not -Throw
    }
}

Describe 'P1-6: Select-CompressionStrategy reads fallback from data' {
    BeforeAll {
        $script:CfgPath = Join-Path $PSScriptRoot '..\..\_internal' 'data' 'strategies.json'
        $script:Cfg     = Get-Strategies -JsonPath $script:CfgPath
    }

    It 'qpdf-lossless selection with ratio >= image_ratio_high routes via the JSON fallback' {
        # Mid-DPI scan -> qpdf-lossless gated to gs-light-regenerate fallback.
        $m = [pscustomobject]@{ hasImages = $true; imageRatio = 0.85; avgDpi = 120 }
        $sel = Select-CompressionStrategy -Metrics $m -Strategies $script:Cfg
        $sel.strategy_id | Should -Be 'qpdf-lossless'
        $sel.fallback    | Should -Be 'gs-light-regenerate'
    }

    It 'qpdf-lossless selection in the text/vector branch (ratio < low) has no fallback' {
        $m = [pscustomobject]@{ hasImages = $true; imageRatio = 0.1; avgDpi = 150 }
        $sel = Select-CompressionStrategy -Metrics $m -Strategies $script:Cfg
        $sel.strategy_id | Should -Be 'qpdf-lossless'
        $sel.fallback    | Should -BeNullOrEmpty
    }

    It 'source no longer hardcodes the fallback strategy_id' {
        $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'select_strategy.ps1')
        # The literal must not appear on the same line as `fallback =`.
        $src | Should -Not -Match "fallback\s*=\s*'gs-light-regenerate'"
    }
}

Describe 'P1-6: fallback schema is non-enum (cannot self-reference)' {
    It 'strategies.schema.json declares fallback as type:[string,null] (no enum)' {
        $raw = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'data' 'strategies.schema.json')
        $raw | Should -Match '"fallback":'
        # The fallback block must declare a union type and must NOT declare an
        # enum (which JSON Schema cannot derive from sibling values).
        $raw | Should -Match '"type":\s*\[\s*"string",\s*"null"\s*\]'
        # The fallback object block must not contain an enum directive.
        $m = [regex]::Match($raw, '"fallback":\s*\{[^}]*\}')
        $m.Success | Should -BeTrue
        $m.Value | Should -Not -Match '"enum"'
    }
}
