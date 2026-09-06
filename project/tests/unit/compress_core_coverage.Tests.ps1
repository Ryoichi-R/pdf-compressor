BeforeAll {
    $previousSkipMain = $env:PDFCOMP_SKIP_MAIN
    $env:PDFCOMP_SKIP_MAIN = '1'
    . (Join-Path $PSScriptRoot '..\..\_internal\compress.ps1')
    if ($null -eq $previousSkipMain) { Remove-Item Env:PDFCOMP_SKIP_MAIN -ErrorAction SilentlyContinue }
    else { $env:PDFCOMP_SKIP_MAIN = $previousSkipMain }
}

Describe 'Invoke-CompressOne measured core paths' {
    BeforeEach {
        $script:WorkRoot = Join-Path $TestDrive 'work'
        $script:ResolvedOutputRoot = Join-Path $TestDrive 'output'
        $script:UseOutsideOutputRoot = $false
        [IO.Directory]::CreateDirectory($script:WorkRoot) | Out-Null
        [IO.Directory]::CreateDirectory($script:ResolvedOutputRoot) | Out-Null
        $script:pdfPath = Join-Path $TestDrive 'input.pdf'
        [IO.File]::WriteAllBytes($script:pdfPath, [byte[]]::new(1000))
        $script:pdf = Get-Item -LiteralPath $script:pdfPath
        $script:outPath = Join-Path $script:ResolvedOutputRoot 'input.compressed.pdf'
        Remove-Item -LiteralPath $script:outPath -Force -ErrorAction SilentlyContinue
        $script:tools = [pscustomobject]@{ qpdf='missing-qpdf'; pdfinfo='missing-pdfinfo'; pdfimages='missing-pdfimages'; pdfsig='missing-pdfsig'; pdfdetach='missing-pdfdetach'; ghostscript='missing-ghostscript'; capabilities=$null }
        $script:strategies = [pscustomobject]@{ allowed_dpi=@(120,150,180); strategies=@() }
        $script:context = [pscustomobject]@{ seen_map=@{}; use_outside_output_root=$false }
        $script:StrategyOverride = 'qpdf-lossless'
        $script:CancelFile = $null

        Mock Get-PdfMetrics { [pscustomobject]@{ error=$null; pageCount=1; fileSize=1000; imageCount=0; imageBytes=0; imageRatio=0; avgDpi=$null; hasImages=$false; encodings=@{}; pageImageDensity=0; warnings=@() } }
        Mock Select-CompressionStrategy { [pscustomobject]@{strategy_id='qpdf-lossless';reason='unit-core';fallback=$null} }
        Mock Get-StrategyCandidates { @([pscustomobject]@{strategy_id='qpdf-lossless';quality_rank=1}) }
        Mock Get-StrategyById { [pscustomobject]@{ strategy_id='qpdf-lossless'; tool='qpdf'; params=[pscustomobject]@{} } }
        Mock Resolve-OutputPath { $script:outPath }
        Mock Restore-PendingOutputTransaction { [pscustomobject]@{status='none'} }
        Mock Assert-WritePathInsideTool { param($TargetPath) $TargetPath }
        Mock Invoke-Qpdf {
            param($QpdfExe,$InputPdf,$OutputPdf,$Linearize)
            [IO.File]::WriteAllBytes($OutputPdf, [byte[]]::new(100))
            [pscustomobject]@{success=$true;exitCode=0;tool='qpdf';stderr='';command=@()}
        }
        Mock Invoke-OutputTransaction {
            param($CandidatePath,$OutputPath,$ReplaceExisting)
            Copy-Item -LiteralPath $CandidatePath -Destination $OutputPath -Force
        }
    }

    It 'commits a smaller candidate and returns a measured success result' {
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off
        $result.status | Should -Be 'ok'
        $result.strategy_id | Should -Be 'qpdf-lossless'
        $result.compressed | Should -Be 100
        $result.ratio_pct | Should -Be -90
        Should -Invoke Invoke-OutputTransaction -Times 1
    }

    It 'honors a cancel marker created while the external compressor is running' {
        $script:CancelFile = Join-Path $script:WorkRoot 'cancel-during-tool.request'
        Mock Invoke-Qpdf {
            param($QpdfExe,$InputPdf,$OutputPdf,$Linearize)
            [IO.File]::WriteAllBytes($OutputPdf, [byte[]]::new(100))
            [IO.File]::WriteAllText($script:CancelFile, 'cancel')
            [pscustomobject]@{success=$true;exitCode=0;tool='qpdf';stderr='';command=@()}
        }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off -ItemCancelFile $script:CancelFile
        $result.status | Should -Be 'fail'
        $result.fail_reason | Should -Be 'aborted'
        $result.stop_reason | Should -Be 'aborted'
        Test-Path -LiteralPath $script:outPath | Should -BeFalse
        Should -Invoke Invoke-OutputTransaction -Times 0
    }

    It 'selects a valid smallest candidate even when a target is not met' {
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off -ItemTargetBytes 50
        $result.status | Should -Be 'ok'
        $result.target_status | Should -Be 'not-met'
        $result.target_met | Should -BeFalse
        $result.stop_reason | Should -Be 'target-not-met'
    }

    It 'maps a candidate that is not smaller to no-effect without touching output' {
        Mock Invoke-Qpdf {
            param($QpdfExe,$InputPdf,$OutputPdf,$Linearize)
            [IO.File]::WriteAllBytes($OutputPdf, [byte[]]::new(1000))
            [pscustomobject]@{success=$true;exitCode=0;tool='qpdf';stderr='';command=@()}
        }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off
        $result.status | Should -Be 'skip'
        $result.fail_reason | Should -Be 'no-effect'
        Should -Invoke Invoke-OutputTransaction -Times 0
    }

    It 'reports tool crash and missing candidate output' -ForEach @(
        @{ Success=$false; Writes=$false; Expected='tool-crashed' },
        @{ Success=$true; Writes=$false; Expected='output-missing' }
    ) {
        Mock Invoke-Qpdf {
            param($QpdfExe,$InputPdf,$OutputPdf,$Linearize)
            if ($Writes) { [IO.File]::WriteAllBytes($OutputPdf, [byte[]]::new(10)) }
            [pscustomobject]@{success=$Success;exitCode=9;tool='qpdf';stderr='failed';command=@()}
        }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off
        $result.status | Should -Be 'fail'
        $result.fail_reason | Should -Be $Expected
    }

    It 'skips an existing output unless force is requested' {
        [IO.File]::WriteAllBytes($script:outPath, [byte[]]::new(55))
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off
        $result.status | Should -Be 'skip'
        $result.fail_reason | Should -Be 'exists'
        $result.compressed | Should -Be 55
    }

    It 'returns analyzer exceptions and analyzer error results distinctly' {
        Mock Get-PdfMetrics { throw 'analysis broke' }
        $thrown = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off
        $thrown.fail_reason | Should -Be 'analyze-exception'
        $thrown.warnings[0] | Should -Match 'analysis broke'

        Mock Get-PdfMetrics { [pscustomobject]@{error='encrypted';tool='pdfinfo'} }
        $reported = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off
        $reported.fail_reason | Should -Be 'encrypted'
        $reported.tool | Should -Be 'pdfinfo'
    }

    It 'returns a structured preflight result with a safety decision' {
        $qpdf = Join-Path $TestDrive 'qpdf.exe'; Set-Content -LiteralPath $qpdf -Value x
        $pdfinfo = Join-Path $TestDrive 'pdfinfo.exe'; Set-Content -LiteralPath $pdfinfo -Value x
        $script:tools.qpdf = $qpdf; $script:tools.pdfinfo = $pdfinfo
        Mock Get-PdfStructureSnapshot { [pscustomobject]@{status='verified';page_count=1;pages=@();reasons=@()} }
        Mock Get-PdfFeatures { [pscustomobject]@{features=[pscustomobject]@{signatures='absent'}} }
        Mock Get-SafetyDecision { [pscustomobject]@{action='allow';policy_reason='safe';verification_status='verified';reasons=@();warnings=@()} }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Safe -ItemPreflightOnly
        $result.status | Should -Be 'skip'
        $result.fail_reason | Should -Be 'preflight-only'
        $result.analysis.safety_action | Should -Be 'allow'
        $result.analysis.status | Should -Be 'verified'
    }

    It 'honors a safety stop before invoking the compressor' {
        $qpdf = Join-Path $TestDrive 'qpdf.exe'; Set-Content -LiteralPath $qpdf -Value x
        $pdfinfo = Join-Path $TestDrive 'pdfinfo.exe'; Set-Content -LiteralPath $pdfinfo -Value x
        $script:tools.qpdf = $qpdf; $script:tools.pdfinfo = $pdfinfo
        Mock Get-PdfStructureSnapshot { [pscustomobject]@{status='verified';page_count=1;pages=@();reasons=@()} }
        Mock Get-PdfFeatures { [pscustomobject]@{features=[pscustomobject]@{signatures='present'}} }
        Mock Get-SafetyDecision { [pscustomobject]@{action='skip';policy_reason='signed';verification_status='rejected';reasons=@('signed');warnings=@()} }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Safe
        $result.status | Should -Be 'skip'
        $result.fail_reason | Should -Be 'safety-skip'
        Should -Invoke Invoke-Qpdf -Times 0
    }

    It 'skips unavailable capabilities and returns tool-unavailable' {
        $script:tools.capabilities = [pscustomobject]@{entries=[pscustomobject]@{qpdf=[pscustomobject]@{found=$false;path=$null}}}
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -Capabilities $script:tools.capabilities -ItemSafetyMode Off
        $result.fail_reason | Should -Be 'tool-unavailable'
        $result.tool | Should -Be 'qpdf'
    }

    It 'dispatches Ghostscript and lossy-raster strategy definitions' -ForEach @(
        @{Id='gs-downsample-150';Tool='ghostscript'},
        @{Id='gs-raster-readable';Tool='lossy-raster'}
    ) {
        Mock Select-CompressionStrategy { [pscustomobject]@{strategy_id=$Id;reason='dispatch-test';fallback=$null} }
        Mock Get-StrategyById {
            if ($Tool -eq 'ghostscript') { [pscustomobject]@{strategy_id=$Id;tool=$Tool;params=[pscustomobject]@{color_dpi=150;gray_dpi=150}} }
            else { [pscustomobject]@{strategy_id=$Id;tool=$Tool;params=[pscustomobject]@{raster_dpi=120;jpeg_quality=60}} }
        }
        Mock Invoke-Ghostscript { param($GhostscriptExe,$InputPdf,$OutputPdf) [IO.File]::WriteAllBytes($OutputPdf,[byte[]]::new(90)); [pscustomobject]@{success=$true;exitCode=0;tool='ghostscript'} }
        Mock Invoke-LossyRaster { param($GhostscriptExe,$InputPdf,$OutputPdf) [IO.File]::WriteAllBytes($OutputPdf,[byte[]]::new(80)); [pscustomobject]@{success=$true;exitCode=0;tool='lossy-raster'} }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off
        $result.status | Should -Be 'ok'
        $result.tool | Should -Be $Tool
    }

    It 'accepts a verified candidate after structure and feature comparison' {
        $qpdf = Join-Path $TestDrive 'verified-qpdf.exe'; Set-Content -LiteralPath $qpdf -Value x
        $pdfinfo = Join-Path $TestDrive 'verified-pdfinfo.exe'; Set-Content -LiteralPath $pdfinfo -Value x
        $script:tools.qpdf=$qpdf;$script:tools.pdfinfo=$pdfinfo
        Mock Get-PdfStructureSnapshot { [pscustomobject]@{status='verified';page_count=1;pages=@();reasons=@()} }
        Mock Get-PdfFeatures { [pscustomobject]@{features=[pscustomobject]@{digital_signature=[pscustomobject]@{state='absent'};encrypted=[pscustomobject]@{state='absent'}}} }
        Mock Get-SafetyDecision { [pscustomobject]@{action='continue';policy_reason='safe';verification_status='verified';reasons=@();warnings=@()} }
        Mock Validate-CompressedPdf { [pscustomobject]@{accepted=$true;status='verified';reasons=@()} }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Safe
        $result.status | Should -Be 'ok'
        $result.verification_status | Should -Be 'verified'
        Should -Invoke Validate-CompressedPdf -Times 1
    }

    It 'reports target-no-valid-candidate after bounded attempts fail' {
        Mock Invoke-Qpdf { [pscustomobject]@{success=$false;exitCode=9;tool='qpdf'} }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off -ItemTargetBytes 50
        $result.fail_reason | Should -Be 'no-valid-candidate'
        $result.stop_reason | Should -Be 'target-no-valid-candidate'
        $result.target_met | Should -BeFalse
    }

    It 'returns a controlled OCR-unavailable result after compression' {
        Mock Get-OcrCapabilities { [pscustomobject]@{available=$false} }
        Mock Invoke-OcrProvider { [pscustomobject]@{success=$false;status='unavailable'} }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off -ItemEnableOcr $true -ItemOcrLanguages @('eng')
        $result.fail_reason | Should -Be 'ocr-unavailable'
        $result.ocr_status | Should -Be 'skipped'
    }

    It 'promotes a validated OCR result' {
        Mock Get-OcrCapabilities { [pscustomobject]@{available=$true} }
        Mock Invoke-OcrProvider {
            param($OcrCapabilities,$InputPdf,$OutputPdf)
            [IO.File]::WriteAllBytes($OutputPdf,[byte[]]::new(70))
            [pscustomobject]@{success=$true;status='applied'}
        }
        Mock Get-PdfStructureSnapshot { [pscustomobject]@{status='verified';page_count=1;pages=@();reasons=@()} }
        Mock Get-PdfFeatures { [pscustomobject]@{features=[pscustomobject]@{}} }
        Mock Validate-CompressedPdf { [pscustomobject]@{accepted=$true;status='verified';reasons=@()} }
        $result = Invoke-CompressOne -Pdf $script:pdf -Tools $script:tools -Strategies $script:strategies -OutputContext $script:context -ItemSafetyMode Off -ItemEnableOcr $true -ItemOcrLanguages @('eng')
        $result.status | Should -Be 'ok'
        $result.ocr_status | Should -Be 'applied'
        $result.compressed | Should -Be 70
    }
}

Describe 'compress formatting helpers' {
    It 'maps discovered capabilities to compatibility tool properties and tolerates cache failure' {
        $caps = [pscustomobject]@{paths=[pscustomobject]@{ghostscript='g';qpdf='q';pdfinfo='i';pdfimages='m';pdfdetach='d';pdfsig='s';ocrmypdf='o'};missing_required=@();safe_ready=$true}
        Mock Get-ToolCapabilities { $caps }
        Mock Assert-WritePathInsideTool { throw 'cache denied' }
        $tools = Get-ResolvedTools
        $tools.ghostscript | Should -Be 'g'
        $tools.qpdf | Should -Be 'q'
        $tools.capabilities.safe_ready | Should -BeTrue
    }

    It 'reads optional properties from null, dictionaries, and objects' {
        Get-OptionalProperty -Object $null -Name x -Default fallback | Should -Be fallback
        Get-OptionalProperty -Object @{x=1} -Name x | Should -Be 1
        Get-OptionalProperty -Object ([pscustomobject]@{x=2}) -Name x | Should -Be 2
        Get-OptionalProperty -Object ([pscustomobject]@{}) -Name x -Default 3 | Should -Be 3
        Get-ResultProperty -Object ([pscustomobject]@{x=4}) -Name x | Should -Be 4
    }

    It 'emits status only when enabled and writes JSONL result records' {
        $script:StatusJson = $false
        Write-StatusJsonLine -Payload ([ordered]@{event='none'}) | Should -BeNullOrEmpty
        $script:StatusJson = $true
        { Write-StatusJsonLine -Payload ([ordered]@{event='test';value=1}) } | Should -Not -Throw

        $log = Join-Path $TestDrive 'result.jsonl'
        $result = [pscustomobject]@{item_id='1';file='x.pdf';status='ok';strategy_id='qpdf-lossless';tool='qpdf';original=100;compressed=50;ratio_pct=-50;fail_reason=$null;warnings=@();mode='auto';safety_mode='Off';features=$null;selection_reason='test';verification_status='not-run';verification_reasons=@();target_bytes=$null;target_status='not-requested';target_met=$null;attempt_count=1;stop_reason=$null;ocr_status='disabled';policy_reason=$null;output_path='out.pdf'}
        { Write-ResultLine -Res $result -Jsonl $log -Index 1 -EmitStatusJson $true } | Should -Not -Throw
        Test-Path -LiteralPath $log | Should -BeTrue
    }

    It 'formats skip and fail result lines including warnings and status events' {
        $log = Join-Path $TestDrive 'other-results.jsonl'
        $base = [ordered]@{item_id='1';file='x.pdf';status='skip';strategy_id=$null;tool='qpdf';original=100;compressed=100;ratio_pct=0;fail_reason='exists';warnings=@();mode='auto';safety_mode='Off';features=$null;selection_reason='test';verification_status='not-run';verification_reasons=@();target_bytes=$null;target_status='not-requested';target_met=$null;attempt_count=0;stop_reason=$null;ocr_status='disabled';policy_reason=$null;output_path='out.pdf'}
        $script:StatusJson = $false
        Write-ResultLine -Res ([pscustomobject]$base) -Jsonl $log
        $base.status='fail';$base.fail_reason='tool-crashed';$base.warnings=@('redacted failure');$base.verification_reasons=@('media-box-mismatch')
        $script:StatusJson = $true
        Write-ResultLine -Res ([pscustomobject]$base) -Jsonl $log -Index 2 -EmitStatusJson $true
        (Get-Content -LiteralPath $log).Count | Should -Be 2
    }
}
