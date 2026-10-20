BeforeAll {
    $env:PDFCOMP_SKIP_MAIN = '1'
    . (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
}

AfterAll {
    Remove-Item Env:PDFCOMP_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'compress_result policy (no-effect handling, structural check)' {
    It 'compress.ps1 contains output-too-large -> no-effect mapping' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $code | Should -Match 'output-too-large'
        $code | Should -Match "fail_reason\s*=\s*'no-effect'"
        $code | Should -Match '\$result\.compressed\s*=\s*\$originalSize'
    }

    It 'reports the original size when every candidate has no effect' {
        $inputPath = Join-Path $TestDrive 'input.pdf'
        $outputPath = Join-Path $TestDrive 'output\input.compressed.pdf'
        $workPath = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
        New-Item -ItemType Directory -Path $workPath -Force | Out-Null
        [System.IO.File]::WriteAllBytes($inputPath, [byte[]]::new(32))
        $pdf = Get-Item -LiteralPath $inputPath

        Mock Get-PdfMetrics {
            [pscustomobject]@{ error = $null; warnings = @() }
        }
        Mock Select-CompressionStrategy {
            [pscustomobject]@{
                strategy_id = 'qpdf-lossless'
                fallback = $null
                reason = 'test'
            }
        }
        Mock Resolve-OutputPath { $outputPath }
        Mock New-WorkSubdirectory { $workPath }
        Mock Assert-WritePathInsideTool {
            param($TargetPath)
            $TargetPath
        }
        Mock Get-StrategyById {
            [pscustomobject]@{
                strategy_id = 'qpdf-lossless'
                tool = 'qpdf'
                params = [pscustomobject]@{}
            }
        }
        Mock Invoke-Qpdf {
            param($QpdfExe, $InputPdf, $OutputPdf)
            [System.IO.File]::WriteAllBytes($OutputPdf, [byte[]]::new(64))
            [pscustomobject]@{ success = $true; tool = 'qpdf'; exitCode = 0 }
        }

        $tools = [pscustomobject]@{
            qpdf = 'qpdf.exe'
            pdfinfo = 'pdfinfo.exe'
            pdfimages = 'pdfimages.exe'
        }
        $strategies = [pscustomobject]@{ allowed_dpi = @(150) }
        $result = Invoke-CompressOne -Pdf $pdf -Tools $tools -Strategies $strategies

        $result.status | Should -Be 'skip'
        $result.fail_reason | Should -Be 'no-effect'
        $result.original | Should -Be 32
        $result.compressed | Should -Be 32
        $result.ratio_pct | Should -Be 0
        Test-Path -LiteralPath $outputPath | Should -BeFalse
    }

    It 'compress.ps1 uses tmp output and the durable transaction helper' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $code | Should -Match 'Join-Path \$work ''out.pdf'''
        $code | Should -Match 'Invoke-OutputTransaction -CandidatePath \$tmpOut'
    }

    It 'does not move formal output before validation and preserves old output on validation reject' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $validationIndex = $code.IndexOf('Validate-CompressedPdf')
        $moveIndex = $code.IndexOf('Invoke-OutputTransaction -CandidatePath $tmpOut')
        $validationIndex | Should -BeGreaterThan -1
        $moveIndex | Should -BeGreaterThan $validationIndex
        $code | Should -Match 'if \(-not \$validation\.accepted\).*continue'

        $inputPath = Join-Path $TestDrive 'input.pdf'
        $outputPath = Join-Path $TestDrive 'output\input.compressed.pdf'
        $workPath = Join-Path $TestDrive 'work-reject'
        New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
        New-Item -ItemType Directory -Path $workPath -Force | Out-Null
        [System.IO.File]::WriteAllBytes($inputPath, [byte[]](1..32))
        Set-Content -LiteralPath $outputPath -Value 'old-formal-output' -Encoding ascii
        $pdf = Get-Item -LiteralPath $inputPath
        $fakeQpdf = Join-Path $TestDrive 'qpdf.exe'
        $fakePdfinfo = Join-Path $TestDrive 'pdfinfo.exe'
        $fakePdfimages = Join-Path $TestDrive 'pdfimages.exe'
        foreach ($path in @($fakeQpdf,$fakePdfinfo,$fakePdfimages)) { Set-Content -LiteralPath $path -Value 'placeholder' -Encoding ascii }

        Mock Get-PdfMetrics { [pscustomobject]@{ error = $null; warnings = @(); pageCount = 1; imageRatio = 0; avgDpi = $null; hasImages = $false } }
        Mock Select-CompressionStrategy { [pscustomobject]@{ strategy_id = 'qpdf-lossless'; fallback = $null; reason = 'test' } }
        Mock Resolve-OutputPath { $outputPath }
        Mock New-WorkSubdirectory { $workPath }
        Mock Assert-WritePathInsideTool { param($TargetPath) $TargetPath }
        Mock Get-StrategyById { [pscustomobject]@{ strategy_id = 'qpdf-lossless'; tool = 'qpdf'; params = [pscustomobject]@{} } }
        Mock Invoke-Qpdf {
            param($QpdfExe, $InputPdf, $OutputPdf)
            [System.IO.File]::WriteAllBytes($OutputPdf, [byte[]](1..16))
            [pscustomobject]@{ success = $true; tool = 'qpdf'; exitCode = 0 }
        }
        Mock Get-PdfStructureSnapshot { [pscustomobject]@{ status='verified'; page_count=1; pages=@() } }
        Mock Get-PdfFeatures {
            [pscustomobject]@{ features = [pscustomobject]@{
                digital_signature = [pscustomobject]@{ state = 'absent' }
                encrypted = [pscustomobject]@{ state = 'absent' }
            } }
        }
        Mock Validate-CompressedPdf { [pscustomobject]@{ accepted=$false; status='rejected'; reasons=@('qpdf-output-error') } }

        $tools = [pscustomobject]@{ qpdf = $fakeQpdf; pdfinfo = $fakePdfinfo; pdfimages = $fakePdfimages; pdfsig = $null; pdfdetach = $null }
        $strategies = [pscustomobject]@{ allowed_dpi = @(150) }
        $context = [pscustomobject]@{ seen_map = @{}; use_outside_output_root = $false }
        $result = Invoke-CompressOne -Pdf $pdf -Tools $tools -Strategies $strategies -OutputContext $context -ItemForce:$true

        $result.status | Should -Be 'fail'
        $result.fail_reason | Should -Be 'validation-rejected'
        $result.verification_reasons | Should -Contain 'qpdf-output-error'
        (Get-Content -LiteralPath $outputPath -Raw) | Should -Be ("old-formal-output" + [Environment]::NewLine)
        Test-Path -LiteralPath ($outputPath + '.bak.') | Should -BeFalse
    }


    It 'uses a one-device-pixel structure tolerance only for lossy raster candidates' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $code | Should -Match '\$structureBoxTolerance\s*=\s*\[decimal\]0\.01'
        $code | Should -Match '\$structureBoxTolerance\s*=\s*\[decimal\]\(72\.0\s*/\s*\[double\]\$rasterDpi\)'
        $code | Should -Match '-StructureBoxTolerance\s+\$structureBoxTolerance'
    }

    It 'keeps exit code 6 behind failure and exists priorities' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $code | Should -Match 'if \(\$failN -gt 0\) \{ return 1 \}'
        $code | Should -Match 'if \(-not \$Force -and \$existsN -gt 0\) \{ return 4 \}'
        $code | Should -Match 'if \(\$actionN -gt 0\) \{ return 6 \}'
    }

    It 'compress.ps1 deletes _work\ subdir in finally{}' {
        $code = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $code | Should -Match 'finally\s*\{\s*Remove-Item\s+-LiteralPath\s+\$work\s+-Recurse\s+-Force'
    }
}
