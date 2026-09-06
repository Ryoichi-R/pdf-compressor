BeforeAll {
    $script:compressPs1 = Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1'
    $script:code = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:compressPs1
}

Describe 'compress.ps1 parameter surface (structural)' {
    It 'declares -OutputRoot parameter' {
        $script:code | Should -Match '\[string\]\$OutputRoot'
    }
    It 'declares -StrategyOverride with ValidateSet' {
        $script:code | Should -Match "ValidateSet\('auto','qpdf-lossless','gs-downsample-150','gs-downsample-180','gs-light-regenerate','gs-raster-low-quality','gs-raster-readable'\)"
        $script:code | Should -Match '\[string\]\$StrategyOverride'
    }
    It 'declares -StatusJson switch' {
        $script:code | Should -Match '\[switch\]\$StatusJson'
    }
    It 'preserves existing -Force, -InputPath, -LogPath parameters (backwards compat)' {
        $script:code | Should -Match '\[string\]\$InputPath'
        $script:code | Should -Match '\[switch\]\$Force'
        $script:code | Should -Match '\[string\]\$LogPath'
    }
}

Describe 'compress.ps1 OutputRoot routing' {
    It 'separates LogPath default from OutputRoot (LogPath stays under tool root)' {
        # LogPathDefault is anchored to the default output dir inside the tool root.
        $script:code | Should -Match '\$script:LogPathDefault\s*=\s*Join-Path'
        $script:code | Should -Match "Join-Path\s+\`$script:ToolRoot\s+'output'"
        $script:code | Should -Match "'compress\.log\.jsonl'"
        $script:code | Should -Match 'if \(-not \$LogPath\) \{ \$LogPath = \$script:LogPathDefault \}'
        # LogPath must always pass the inside-tool guard.
        $script:code | Should -Match 'Assert-WritePathInsideTool -TargetPath \$LogPath'
    }
    It 'gates explicit OutputRoot through Assert-OutputPathLocal' {
        $script:code | Should -Match 'Assert-OutputPathLocal -TargetPath \$OutputRoot'
    }
    It 'final output directory uses Assert-OutputPathLocal when OutputRoot is external' {
        $script:code | Should -Match 'if \(\$OutputContext -and \$OutputContext\.use_outside_output_root\)\s*\{'
        $script:code | Should -Match 'Assert-OutputPathLocal -TargetPath \$outputDir'
    }
}

Describe 'compress.ps1 StatusJson emission' {
    It 'emits ##STATUS## marker' {
        $script:code | Should -Match '##STATUS##'
    }
    It 'declares start/file/summary event payloads' {
        $script:code | Should -Match "event\s*=\s*'start'"
        $script:code | Should -Match "event\s*=\s*'summary'"
        $script:code | Should -Match "event\s*=\s*'file'"
    }
    It 'guards status emission with $StatusJson switch' {
        $script:code | Should -Match 'if \(\$StatusJson\)'
        $script:code | Should -Match 'if \(-not \$StatusJson\) \{ return \}'
    }
}

Describe 'compress.ps1 StrategyOverride' {
    It 'overrides strategy_id when StrategyOverride is non-auto' {
        $script:code | Should -Match 'if \(\$StrategyOverride -and \$StrategyOverride -ne ''auto''\)'
        $script:code | Should -Match 'strategy_id\s*=\s*\$StrategyOverride'
    }
}

Describe 'compress.ps1 Strategies caching (P1-3 N+1 elimination)' {
    It 'loads strategies once at startup and stores on the script scope' {
        $script:code | Should -Match '\$script:Strategies\s*=\s*Get-Strategies\s+-JsonPath\s+\$script:StrategiesPath'
    }
    It 'passes the cached object into Invoke-CompressOne' {
        $script:code | Should -Match 'Invoke-CompressOne -Pdf \$f -Tools \$tools -Strategies \$script:Strategies'
    }
    It 'Invoke-CompressOne declares a mandatory -Strategies parameter' {
        $script:code | Should -Match '\[Parameter\(Mandatory\)\]\[object\]\$Strategies'
    }
    It 'no per-attempt Get-Strategies inside the foreach attempt loop' {
        # The earlier N+1 site was Get-Strategies inside `foreach ($sid in $attempts)`.
        # The cached object must be referenced via $Strategies instead.
        $loopIdx = $script:code.IndexOf('foreach ($sid in $attempts)')
        $loopIdx | Should -BeGreaterThan 0
        # Within ~40 lines after the loop opens, no Get-Strategies call should appear.
        $window = $script:code.Substring($loopIdx, [math]::Min(2000, $script:code.Length - $loopIdx))
        $window | Should -Not -Match 'Get-Strategies\s+-JsonPath'
    }
    It 'Select-CompressionStrategy is called with -Strategies (not -ConfigPath)' {
        $script:code | Should -Match 'Select-CompressionStrategy -Metrics \$metrics -Strategies \$Strategies'
    }
}

Describe 'compress.ps1 lossy raster strategy wiring' {
    It 'dot-sources invoke_lossy_raster.ps1' {
        $script:code | Should -Match "invoke_lossy_raster\.ps1"
    }

    It 'dispatches tool=lossy-raster to Invoke-LossyRaster' {
        $script:code | Should -Match "'lossy-raster'\s*\{"
        $script:code | Should -Match 'Invoke-LossyRaster'
        $script:code | Should -Match '-RasterDpi\s+\$rasterDpi'
    }
}
