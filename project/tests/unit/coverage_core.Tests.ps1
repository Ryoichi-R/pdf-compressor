BeforeAll {
    $internal = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internal 'analyze_pdf.ps1')
    . (Join-Path $internal 'pdf-structure.ps1')
    . (Join-Path $internal 'tool-resolver.ps1')
    . (Join-Path $internal 'tool-capabilities.ps1')
    . (Join-Path $internal 'select_strategy.ps1')
    . (Join-Path $internal 'target-size.ps1')
    . (Join-Path $internal 'invoke_qpdf.ps1')
    . (Join-Path $internal 'invoke_ghostscript.ps1')
    . (Join-Path $internal 'invoke_lossy_raster.ps1')
    . (Join-Path $internal 'log-format.ps1')
}

Describe 'core coverage: analyzer' {
    BeforeEach {
        $script:samplePdf = Join-Path $TestDrive 'sample.pdf'
        [IO.File]::WriteAllBytes($script:samplePdf, [byte[]]::new(1000))
    }

    It 'computes image metrics, masks, warnings, median DPI, and encodings' {
        Mock Get-PdfInfo { @{ rc = 0; output = "Pages: 2`nEncrypted: no" } }
        Mock Get-PdfImagesList {
            @{ rc = 0; output = @(
                'page num type width height color comp bpc enc interp object ID x-ppi y-ppi size ratio',
                '1 0 image 100 100 rgb 3 8 jpeg no 1 0 150 140 400 1%',
                '1 1 smask 100 100 gray 1 8 image no 2 0 150 150 100 1%',
                '2 2 image 100 100 rgb 3 8 jpeg no 3 0 300 200 300 1%',
                '2 3 image 100 100 rgb 3 8 flate no 4 0 - - - 1%'
            ) }
        }
        $result = Get-PdfMetrics -PdfPath $script:samplePdf -PdfInfoExe 'fake-info' -PdfImagesExe 'fake-images'
        $result.error | Should -BeNullOrEmpty
        $result.pageCount | Should -Be 2
        $result.imageCount | Should -Be 3
        $result.imageBytes | Should -Be 700
        $result.avgDpi | Should -Be 170
        $result.encodings.jpeg | Should -Be 2
        $result.warnings | Should -Contain 'size-parse-failed:p2'
    }

    It 'classifies pdfinfo and pdfimages failures' -ForEach @(
        @{ Stage='info'; Text='password required'; Expected='encrypted' },
        @{ Stage='info'; Text='damaged syntax'; Expected='corrupted' },
        @{ Stage='info'; Text='permission denied'; Expected='permission-denied' },
        @{ Stage='info'; Text='other'; Expected='unknown' },
        @{ Stage='images'; Text='password required'; Expected='encrypted' },
        @{ Stage='images'; Text='invalid syntax'; Expected='corrupted' },
        @{ Stage='images'; Text='permission denied'; Expected='permission-denied' },
        @{ Stage='images'; Text='other'; Expected='unknown' }
    ) {
        Mock Get-PdfInfo { if ($Stage -eq 'info') { @{ rc=1; output=$Text } } else { @{ rc=0; output='Pages: 1' } } }
        Mock Get-PdfImagesList { @{ rc=1; output=$Text } }
        (Get-PdfMetrics -PdfPath $script:samplePdf -PdfInfoExe x -PdfImagesExe y).error | Should -Be $Expected
    }

    It 'reports missing input' {
        (Get-PdfMetrics -PdfPath (Join-Path $TestDrive 'missing.pdf') -PdfInfoExe x -PdfImagesExe y).error | Should -Be 'input-missing'
    }

    It 'covers remaining size suffixes and malformed image rows' {
        (Convert-SizeToBytes '2G').bytes | Should -Be 2147483648
        (Convert-SizeToBytes '1GiB').bytes | Should -Be 1073741824
        (Convert-SizeToBytes '4XB').warn | Should -BeTrue
        (ConvertFrom-PdfImagesList @('not a header', 'page num type', 'too short')).Count | Should -Be 0
    }
}

Describe 'core coverage: PDF structure' {
    It 'normalizes boxes and rotations including invalid values' {
        (ConvertTo-StructureBox @('0','0','612.0','792.0'))[2] | Should -Be 612
        ConvertTo-StructureBox @('bad','0','1','2') | Should -BeNullOrEmpty
        ConvertTo-StructureBox @('1','2','3') | Should -BeNullOrEmpty
        ConvertTo-NormalizedRotation -Value -90 | Should -Be 270
        ConvertTo-NormalizedRotation -Value 45 | Should -BeNullOrEmpty
        ConvertTo-NormalizedRotation -Value bad | Should -BeNullOrEmpty
    }

    It 'parses global and per-page boxes and complete rotations' {
        $lines = @(
            'Pages: 2', 'MediaBox: 0 0 612 792', 'CropBox: 0 0 600 780',
            'Page 1 MediaBox: 0 0 612 792', 'Page 1 CropBox: 1 2 600 780', 'Page 1 rot: 0',
            'Page 2 size: 612 x 792 pts', 'Page rot: 90'
        )
        $parsed = Get-PdfInfoPageRecords -Lines $lines
        $parsed.records[1].crop_box[0] | Should -Be 1
        $rotation = Get-PdfInfoRotationMapFromLines -Lines $lines -PageCount 2
        $rotation.available | Should -BeTrue
        $rotation.map[2] | Should -Be 90
    }

    It 'returns indeterminate rotation states' {
        (Get-PdfInfoRotationMapFromLines -Lines @('Page 1 rot: 45') -PageCount 1).warnings | Should -Contain 'rotate-detector-indeterminate'
        (Get-PdfInfoRotationMapFromLines -Lines @('Page 1 rot: 0') -PageCount 2).warnings | Should -Contain 'rotate-detector-incomplete'
        $missingTool = Join-Path $TestDrive 'missing-tool.exe'
        (Get-PdfInfoRotationMap -PdfInfoExe $missingTool -PdfPath x -PageCount 0).warnings | Should -Contain 'rotate-detector-unavailable'
        (Get-PdfRotationMap -QpdfExe $missingTool -PdfInfoExe $missingTool -PdfPath x).warnings | Should -Contain 'rotate-detector-unavailable'
    }

    It 'compares equal and mismatched snapshots' {
        $before = [pscustomobject]@{ page_count=1; pages=@([pscustomobject]@{media_box=@(0,0,10,10);crop_box=@(0,0,10,10);rotate=0}) }
        (Compare-PdfStructureSnapshot $before $before).equal | Should -BeTrue
        $after = [pscustomobject]@{ page_count=2; pages=@([pscustomobject]@{media_box=@(0,0,11,10);crop_box=@(0,0,10,9);rotate=90}) }
        $bad = Compare-PdfStructureSnapshot $before $after
        $bad.equal | Should -BeFalse
        $bad.reasons | Should -Contain 'page-count-mismatch'
        $bad.reasons | Should -Contain 'media-box-mismatch'
        $bad.reasons | Should -Contain 'crop-box-mismatch'
        $bad.reasons | Should -Contain 'rotate-mismatch'
        (Test-StructureBoxEqual @() @()) | Should -BeFalse
    }

    It 'reports a missing PDF snapshot' {
        (Get-PdfStructureSnapshot -PdfPath (Join-Path $TestDrive 'missing.pdf') -PdfInfoExe x).reasons | Should -Contain 'input-missing'
    }

    It 'builds a verified snapshot from deterministic pdfinfo output' {
        $pdf = Join-Path $TestDrive 'structure.pdf'; Set-Content -LiteralPath $pdf -Value '%PDF-test'
        $pdfinfo = Join-Path $TestDrive 'pdfinfo.ps1'
        Set-Content -LiteralPath $pdfinfo -Value @'
"Pages: 2"
"Encrypted: no"
"Page 1 MediaBox: 0 0 612 792"
"Page 1 CropBox: 0 0 600 780"
"Page 1 rot: 0"
"Page 2 MediaBox: 0 0 612 792"
"Page 2 CropBox: 0 0 612 792"
"Page 2 rot: 90"
exit 0
'@
        $snapshot = Get-PdfStructureSnapshot -PdfPath $pdf -PdfInfoExe $pdfinfo -PageCount 2
        $snapshot.status | Should -Be 'verified'
        $snapshot.pages.Count | Should -Be 2
        $snapshot.pages[1].rotate | Should -Be 90
        $snapshot.encryption | Should -Be 'absent'
    }

    It 'classifies failed and encrypted pdfinfo snapshots' -ForEach @(
        @{Text='password encrypted';Expected='encrypted'},
        @{Text='generic failure';Expected='pdfinfo-failed'}
    ) {
        $pdf = Join-Path $TestDrive ("failed-{0}.pdf" -f $Expected); Set-Content -LiteralPath $pdf -Value '%PDF-test'
        $pdfinfo = Join-Path $TestDrive ("failed-{0}.ps1" -f $Expected)
        Set-Content -LiteralPath $pdfinfo -Value "Write-Error '$Text'; exit 2"
        $snapshot = Get-PdfStructureSnapshot -PdfPath $pdf -PdfInfoExe $pdfinfo
        $snapshot.reasons | Should -Contain $Expected
    }

    It 'uses qpdf show-pages as a rotation fallback' {
        $pdf = Join-Path $TestDrive 'rotate.pdf'; Set-Content -LiteralPath $pdf -Value '%PDF-test'
        $qpdf = Join-Path $TestDrive 'show-pages.ps1'
        Set-Content -LiteralPath $qpdf -Value '"page 1"; "rotation: 180"; exit 0'
        $result = Get-PdfRotationMap -QpdfExe $qpdf -PdfInfoExe (Join-Path $TestDrive missing.exe) -PdfPath $pdf -PageCount 1
        $result.available | Should -BeTrue
        $result.map[1] | Should -Be 180
        $result.detector | Should -Be 'qpdf-show-pages'
    }

    It 'runs pdfinfo rotation success and failure paths directly' {
        $pdf = Join-Path $TestDrive 'rotation-direct.pdf';Set-Content -LiteralPath $pdf -Value '%PDF'
        $ok = Join-Path $TestDrive 'rotation-ok.ps1';Set-Content -LiteralPath $ok -Value '"Page 1 rot: 270"; exit 0'
        (Get-PdfInfoRotationMap -PdfInfoExe $ok -PdfPath $pdf -PageCount 1).map[1] | Should -Be 270
        $bad = Join-Path $TestDrive 'rotation-bad.ps1';Set-Content -LiteralPath $bad -Value 'exit 2'
        (Get-PdfInfoRotationMap -PdfInfoExe $bad -PdfPath $pdf -PageCount 1).warnings | Should -Contain 'rotate-detector-failed'
    }

    It 'maps qpdf rotation failure and indeterminate output' {
        $pdf = Join-Path $TestDrive 'rotation-qpdf.pdf';Set-Content -LiteralPath $pdf -Value '%PDF'
        $bad = Join-Path $TestDrive 'qpdf-bad.ps1';Set-Content -LiteralPath $bad -Value 'exit 2'
        (Get-PdfRotationMap -QpdfExe $bad -PdfInfoExe missing -PdfPath $pdf -PageCount 1).warnings | Should -Contain 'rotate-detector-failed'
        $empty = Join-Path $TestDrive 'qpdf-empty.ps1';Set-Content -LiteralPath $empty -Value '"page 1"; exit 0'
        (Get-PdfRotationMap -QpdfExe $empty -PdfInfoExe missing -PdfPath $pdf -PageCount 1).warnings | Should -Contain 'rotate-detector-indeterminate'
    }
}

Describe 'core coverage: capabilities and target policy' {
    It 'discovers available and missing tools through the shared resolver' {
        Mock Find-ToolExecutable { param($Name,$ExtraCandidates) if ($Name -in @('qpdf','pdfinfo','pdfimages')) { 'C:\fake\tool.exe' } else { $null } }
        Mock Get-ToolVersionSafe { '1.2.3' }
        $caps = Get-ToolCapabilities
        $caps.safe_ready | Should -BeTrue
        $caps.entries.qpdf.version | Should -Be '1.2.3'
        $caps.entries.ghostscript.found | Should -BeFalse
        (Get-ToolCapability $caps 'missing').reason | Should -Be 'unknown-capability'
        (Require-ToolCapability $caps qpdf).available | Should -BeTrue
        { Require-ToolCapability $caps ghostscript -Throw } | Should -Throw '*tool-unavailable*'
        (Test-StrategyCapability $caps qpdf-lossless).available | Should -BeTrue
        (Test-StrategyCapability $caps unknown).reason | Should -Be 'unknown-strategy'
    }

    It 'bounds version output and handles version invocation failure' {
        $version = Join-Path $TestDrive 'version.ps1'
        Set-Content -LiteralPath $version -Value ('"' + ('v' * 200) + '"; exit 0')
        (Get-ToolVersionSafe -Path $version).Length | Should -Be 160
        Get-ToolVersionSafe -Path (Join-Path $TestDrive 'missing-version.exe') | Should -Be 'unknown'
    }

    It 'reads a valid cache and ignores a malformed cache' {
        $cache = Join-Path $TestDrive 'cache.json'; Set-Content -LiteralPath $cache -Value '{"qpdf":"C:\\cached\\qpdf.exe"}'
        Mock Find-ToolExecutable { param($Name,$ExtraCandidates) if ($ExtraCandidates.Count) { $ExtraCandidates[0] } else { $null } }
        Mock Get-ToolVersionSafe { 'cached' }
        (Get-ToolCapabilities -CachePath $cache).paths.qpdf | Should -Be 'C:\cached\qpdf.exe'
        Set-Content -LiteralPath $cache -Value '{bad json'
        { Get-ToolCapabilities -CachePath $cache } | Should -Not -Throw
    }

    It 'loads mode definitions and rejects missing/invalid definitions' {
        (Get-ModeDefinitions).Count | Should -BeGreaterThan 0
        (Get-ModeDefinition -Mode auto).mode_id | Should -Be 'auto'
        { Get-ModeDefinition -Mode invalid } | Should -Throw
        { Get-ModeDefinition -Mode auto -Definitions @() } | Should -Not -Throw
        { Get-ModeDefinitions -Path (Join-Path $TestDrive 'missing.json') } | Should -Throw
    }

    It 'selects target candidates with de-duplication, capability and raster filters' {
        $strategies = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\_internal\data\strategies.json') -Raw | ConvertFrom-Json
        $metrics = [pscustomobject]@{ imageRatio=.8; avgDpi=300; hasImages=$true; pageImageDensity=1 }
        $caps = [pscustomobject]@{ entries=[pscustomobject]@{
            qpdf=[pscustomobject]@{found=$true;path='q';version='1'}
            ghostscript=[pscustomobject]@{found=$false;path=$null;version=$null}
        } }
        $result = Get-StrategyCandidates -Mode minimum-size -Metrics $metrics -Strategies $strategies -Capabilities $caps
        @($result).Count | Should -Be 1
        $result[0].strategy_id | Should -Be 'qpdf-lossless'
        (Get-StrategyCandidates -Mode auto -Metrics $metrics -Strategies $strategies -StrategyOverride qpdf-lossless)[0].quality_rank | Should -Be 1
    }

    It 'covers all target result outcomes and attempt bounding' {
        $none = Select-BestTargetCandidate -Candidates @([pscustomobject]@{valid=$false;bytes=1}) -TargetBytes 10
        $none.target_status | Should -Be 'no-valid-candidate'
        $met = Select-BestTargetCandidate -Candidates @(
            [pscustomobject]@{valid=$true;bytes=9;quality_rank=2},
            [pscustomobject]@{valid=$true;bytes=8;quality_rank=1}
        ) -TargetBytes 10 -OriginalBytes 100
        $met.selected.quality_rank | Should -Be 1
        $notMet = Select-BestTargetCandidate -Candidates @(
            [pscustomobject]@{valid=$true;bytes=30;quality_rank=1},
            [pscustomobject]@{valid=$true;bytes=20;quality_rank=2}
        ) -TargetBytes 10 -OriginalBytes 100 -StopReason exhausted
        $notMet.best_valid_bytes | Should -Be 20
        $notMet.stop_reason | Should -Be 'exhausted'
        (Test-TargetBytes $null) | Should -BeFalse
    }
}

Describe 'core coverage: wrappers and formatting' {
    BeforeEach {
        $script:inputPdf = Join-Path $TestDrive 'input.pdf'
        [IO.File]::WriteAllBytes($script:inputPdf, [byte[]]::new(100))
    }

    It 'covers wrapper missing-input and argument validation paths' {
        $fake = Join-Path $TestDrive 'fake.exe'; Set-Content -LiteralPath $fake -Value x
        (Invoke-Qpdf -QpdfExe $fake -InputPdf (Join-Path $TestDrive missing.pdf) -OutputPdf out).stderr | Should -Match 'input missing'
        (Invoke-Ghostscript -GhostscriptExe $fake -InputPdf (Join-Path $TestDrive missing.pdf) -OutputPdf out -ColorDpi 150 -GrayDpi 150 -AllowedDpi @(150)).stderr | Should -Match 'input missing'
        (Invoke-LossyRaster -GhostscriptExe $fake -InputPdf (Join-Path $TestDrive missing.pdf) -OutputPdf out -RasterDpi 150 -JpegQuality 70).stderr | Should -Match 'input missing'
        { Invoke-LossyRaster -GhostscriptExe x -InputPdf x -OutputPdf x -RasterDpi 50 -JpegQuality 70 } | Should -Throw
        { Invoke-LossyRaster -GhostscriptExe x -InputPdf x -OutputPdf x -RasterDpi 150 -JpegQuality 101 } | Should -Throw
    }

    It 'runs qpdf success and warning exits with array arguments' -ForEach @(0,3) {
        $tool = Join-Path $TestDrive ("qpdf-{0}.ps1" -f $_)
        Set-Content -LiteralPath $tool -Value @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Rest)
Copy-Item -LiteralPath `$Rest[-2] -Destination `$Rest[-1] -Force
exit $_
"@
        $output = Join-Path $TestDrive ("qpdf-{0}-out.pdf" -f $_)
        $result = Invoke-Qpdf -QpdfExe $tool -InputPdf $script:inputPdf -OutputPdf $output -Linearize
        $result.success | Should -BeTrue
        $result.exitCode | Should -Be $_
        $result.command | Should -Contain '--linearize'
    }

    It 'runs Ghostscript and lossy-raster success paths' {
        $tool = Join-Path $TestDrive 'ghostscript.ps1'
        Set-Content -LiteralPath $tool -Value @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$outputArg = $Rest | Where-Object { $_ -like '-sOutputFile=*' } | Select-Object -First 1
$output = $outputArg.Substring('-sOutputFile='.Length)
Copy-Item -LiteralPath $Rest[-1] -Destination $output -Force
exit 0
'@
        $gsOut = Join-Path $TestDrive 'gs-out.pdf'
        $gs = Invoke-Ghostscript -GhostscriptExe $tool -InputPdf $script:inputPdf -OutputPdf $gsOut -ColorDpi 150 -GrayDpi 150 -AllowedDpi @(150) -DownsampleMono
        $gs.success | Should -BeTrue
        $gs.command | Should -Contain '-dDownsampleMonoImages=true'
        $rasterOut = Join-Path $TestDrive 'raster-out.pdf'
        $raster = Invoke-LossyRaster -GhostscriptExe $tool -InputPdf $script:inputPdf -OutputPdf $rasterOut -RasterDpi 120 -JpegQuality 65
        $raster.success | Should -BeTrue
        $raster.command | Should -Contain '-dJPEGQ=65'
    }

    It 'formats sizes and stable result/status records' {
        Format-Size 1073741824 | Should -Be '1.0 GB'
        Format-Size 1048576 | Should -Be '1.0 MB'
        Format-Size 1024 | Should -Be '1.0 KB'
        Format-Size 5 | Should -Be '5 B'
        $record = ConvertTo-JsonlResultRecord ([pscustomobject]@{file='a.pdf';status='ok';ignored='x'})
        $record.file | Should -Be 'a.pdf'
        $record.Contains('ts') | Should -BeTrue
        $evt = ConvertTo-StatusEvent -Event file -Payload ([pscustomobject]@{status='ok';count=1})
        $evt.event | Should -Be 'file'
        $evt.status | Should -Be 'ok'
    }
}
