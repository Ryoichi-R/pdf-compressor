BeforeAll {
    $script:compressPs1 = Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1'
    $script:code = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:compressPs1
}

Describe 'compress.ps1 exit code policy (P1-2)' {
    It 'returns exit 3 for a nonexistent input path' {
        $missingPath = Join-Path $TestDrive 'missing.pdf'
        $outputRoot = Join-Path $TestDrive 'output'
        $pwshExe = (Get-Process -Id $PID).Path

        $childOutput = & $pwshExe -NoProfile -File $script:compressPs1 `
            -InputPath $missingPath -OutputRoot $outputRoot 2>&1 | Out-String
        $childExitCode = $LASTEXITCODE

        $childExitCode | Should -Be 3
        $childOutput | Should -Match 'Input path not found'
    }

    It 'counts existsN by inspecting fail_reason on skip results' {
        $script:code | Should -Match '\$existsN\s*=\s*0'
        $script:code | Should -Match '\$res\.fail_reason\s+-eq\s+''exists'''
        $script:code | Should -Match '\$existsN\+\+'
    }

    It 'emits the [INFO] hint when existsN > 0 and -Force is not set' {
        $script:code | Should -Match 'if \(\$existsN -gt 0 -and -not \$Force\)'
        $script:code | Should -Match 'Re-run with --Force'
    }

    It 'final exit ladder: failN>0 -> 1, then existsN>0 && !Force -> 4, then trailing exit 0' {
        # Order matters: fail must dominate exists; the FINAL exit 0 is the
        # post-summary fallback (not the early no-files exit 0).
        $failIdx   = $script:code.IndexOf('if ($failN -gt 0) { return 1 }')
        $existsIdx = $script:code.IndexOf('if (-not $Force -and $existsN -gt 0) { return 4 }')
        $finalZero = $script:code.LastIndexOf('return 0')

        $failIdx   | Should -BeGreaterThan 0
        $existsIdx | Should -BeGreaterThan $failIdx
        $finalZero | Should -BeGreaterThan $existsIdx
        $script:code | Should -Match 'exit \(Invoke-PdfCompressorMain @PSBoundParameters\)'
    }

    It 'StatusJson summary payload includes exists count' {
        $script:code | Should -Match 'exists\s*=\s*\$existsN'
    }

    It 'returns exit 6 when a verified candidate is smaller but misses the requested target' -Tag 'ExternalTool' {
        . (Join-Path $PSScriptRoot '..\..\_internal' 'tool-resolver.ps1')
        $qpdf = Find-ToolExecutable -Name 'qpdf'
        $pdfinfo = Find-ToolExecutable -Name 'pdfinfo'
        $pdfimages = Find-ToolExecutable -Name 'pdfimages'
        if (-not $qpdf -or -not $pdfinfo -or -not $pdfimages) {
            Set-ItResult -Skipped -Because 'qpdf, pdfinfo and pdfimages are required'
            return
        }
        . (Join-Path $PSScriptRoot '..\support\New-SyntheticPdf.ps1')
        $fixture = Join-Path $TestDrive 'target-input.pdf'
        New-SyntheticPdf -OutputPath $fixture -PageCount 1 -TargetBytes 50000 | Out-Null
        $outputRoot = Join-Path $TestDrive 'target-output'
        $pwshExe = (Get-Process -Id $PID).Path
        $childOutput = & $pwshExe -NoProfile -File $script:compressPs1 `
            -InputPath $fixture -OutputRoot $outputRoot -StrategyOverride 'qpdf-lossless' -TargetBytes 1 -StatusJson 2>&1 | Out-String
        $childExitCode = $LASTEXITCODE
        $childExitCode | Should -Be 6
        $childOutput | Should -Match 'target-not-met'
    }
}

Describe 'compress.bat RC dispatch (P1-2)' {
    BeforeAll {
        $script:batPath = Join-Path $PSScriptRoot '..\..\scripts\launchers\compress-dev.bat'
        $script:bat = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:batPath
    }
    It 'handles RC 4 with an [INFO] hint about --Force' {
        $script:bat | Should -Match 'if "%RC%"=="4"'
        $script:bat | Should -Match 'Re-run with --Force'
    }
    It 'still handles RC 5 (path-guard) explicitly' {
        $script:bat | Should -Match 'if "%RC%"=="5"'
    }
}

Describe 'README / ARCHITECTURE document exit 4 policy (P1-2)' {
    It 'README exit-code table marks exit 4 with okN-agnostic semantics' {
        $readme = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot '..\..\_internal' '..' 'README.md')
        $readme | Should -Match '`\[SKIP\] exists`'
        $readme | Should -Match '`okN` の有無は問わない'
    }
    It 'ARCHITECTURE exit-code section enumerates the priority ladder' {
        $arch = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot '..\..\_internal' 'ARCHITECTURE.md')
        $arch | Should -Match 'failN>0 → 1'
        $arch | Should -Match 'existsN>0 && !Force → 4'
        $arch | Should -Match '`\[SKIP\] no-effect` は per-file status'
    }
}
