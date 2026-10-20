Set-StrictMode -Version Latest

BeforeAll {
    $internalRoot = Join-Path $PSScriptRoot '..\..\_internal'
    $projectRoot = Split-Path -Parent $internalRoot
    $fixtureRoot = Join-Path $projectRoot 'tests\fixtures\pdf'
    $matrixPath = Join-Path $fixtureRoot 'fixture-matrix.json'
    $availabilityPath = Join-Path $fixtureRoot 'fixture-availability.json'
    . (Join-Path $internalRoot 'tool-resolver.ps1')
    . (Join-Path $internalRoot 'analyze_pdf.ps1')
    . (Join-Path $internalRoot 'pdf-structure.ps1')
    . (Join-Path $internalRoot 'inspect_pdf_features.ps1')
    . (Join-Path $internalRoot 'validate_output.ps1')
    . (Join-Path $internalRoot 'safety-policy.ps1')
    . (Join-Path $internalRoot 'select_strategy.ps1')
    . (Join-Path $internalRoot 'target-size.ps1')
    . (Join-Path $internalRoot 'tool-capabilities.ps1')
    . (Join-Path $projectRoot 'tests\support\New-SyntheticPdf.ps1')
    $matrix = Get-Content -LiteralPath $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $availability = Get-Content -LiteralPath $availabilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $qpdf = Find-ToolExecutable -Name 'qpdf'
    $pdfinfo = Find-ToolExecutable -Name 'pdfinfo'
    $pdfimages = Find-ToolExecutable -Name 'pdfimages'
    $ghostscript = Find-ToolExecutable -Name 'gswin64c'
    $strategies = Get-Strategies -JsonPath (Join-Path $internalRoot 'data\strategies.json')
}

Describe 'Tier 2 safety fixture matrix contract' -Tag 'E2E','ExternalTool' {
    It 'declares all nine public-v1 coverage sections' {
        @($matrix.scenarios).Count | Should -Be 9
        @($matrix.scenarios.id) | Should -Contain 'text-vector'
        @($matrix.scenarios.id) | Should -Contain 'image-content'
        @($matrix.scenarios.id) | Should -Contain 'multi-page'
        @($matrix.scenarios.id) | Should -Contain 'interactive-features'
        @($matrix.scenarios.id) | Should -Contain 'structure-rotation'
        @($matrix.scenarios.id) | Should -Contain 'standards'
        @($matrix.scenarios.id) | Should -Contain 'security'
        @($matrix.scenarios.id) | Should -Contain 'failure'
        @($matrix.scenarios.id) | Should -Contain 'strategies'
    }

    It 'classifies every fixture without silently skipping deferred classes' {
        @($availability.fixtures).Count | Should -Be 16
        @($availability.fixtures | Where-Object availability -eq 'generated-required').Count | Should -Be 11
        @($availability.fixtures | Where-Object availability -eq 'curated-required').id | Should -Be @('signed')
        @($availability.fixtures | Where-Object availability -eq 'policy-only-deferred').id | Should -Be @('xfa','tagged-javascript-layers','pdfa-pdfx','ocr')
        @($availability.fixtures | Where-Object availability -eq 'policy-only-deferred' | Where-Object { [string]::IsNullOrWhiteSpace($_.blocker) }).Count | Should -Be 0
    }

    It 'detects the hash-pinned curated signature and enforces the signed-PDF boundary' {
        if (-not $qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $entry = $availability.fixtures | Where-Object id -eq 'signed'
        $entry.status | Should -Be 'available'
        $path = Join-Path $fixtureRoot $entry.file
        $provenance = Get-Content -LiteralPath (Join-Path $fixtureRoot $entry.provenance) -Raw -Encoding UTF8 | ConvertFrom-Json
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $provenance.sha256

        $check = Invoke-QpdfCheck -QpdfExe $qpdf -PdfPath $path
        $check.status | Should -Be 'clean'
        $features = Get-PdfFeatures -PdfPath $path -QpdfExe $qpdf
        $features.features.digital_signature.state | Should -Be 'present'

        $defaultDecision = Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'qpdf-lossless'
        $defaultDecision.action | Should -Be 'skip'
        $defaultDecision.reasons | Should -Contain 'signed-pdf'

        $approvedDecision = Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'qpdf-lossless' -AllowSignedPdf
        $approvedDecision.action | Should -Be 'continue'
        $approvedDecision.verification_status | Should -Be 'warning'
        $approvedDecision.warnings | Should -Contain 'signed-pdf-explicitly-allowed-signature-not-preserved'
    }

    It 'detects mixed page rotations in one pdfinfo invocation' {
        if (-not $pdfinfo) {
            Set-ItResult -Skipped -Because 'pdfinfo is not available'
            return
        }
        $path = Join-Path $TestDrive 'generated-rotate-3.pdf'
        New-SyntheticPdf -OutputPath $path -PageCount 3 -RotationByPage @{ 2 = 90; 3 = 180 } | Out-Null
        $snapshot = Get-PdfStructureSnapshot -PdfPath $path -PdfInfoExe $pdfinfo -QpdfExe $qpdf -PageCount 3
        $snapshot.status | Should -Be 'verified'
        $snapshot.rotate_detector | Should -Be 'pdfinfo'
        @($snapshot.pages | ForEach-Object { [int]$_.rotate }) | Should -Be @(0,90,180)
    }

    It 'handles a 60-page structure without per-page detector processes' {
        if (-not $pdfinfo) {
            Set-ItResult -Skipped -Because 'pdfinfo is not available'
            return
        }
        $path = Join-Path $TestDrive 'generated-pages-60.pdf'
        New-SyntheticPdf -OutputPath $path -PageCount 60 | Out-Null
        $snapshot = Get-PdfStructureSnapshot -PdfPath $path -PdfInfoExe $pdfinfo -QpdfExe $qpdf -PageCount 60
        $snapshot.status | Should -Be 'verified'
        $snapshot.page_count | Should -Be 60
        @($snapshot.pages | ForEach-Object { [int]$_.rotate } | Select-Object -Unique) | Should -Be @(0)
    }

    It 'detects generated AcroForm, attachment, outline, and link features' {
        if (-not $qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $path = Join-Path $TestDrive 'generated-interactive.pdf'
        New-SyntheticPdf -OutputPath $path -IncludeAcroForm -IncludeAttachmentsOutlinesLinks | Out-Null
        $features = Get-PdfFeatures -PdfPath $path -QpdfExe $qpdf
        $features.features.acroform.state | Should -Be 'present'
        $features.features.attachments.state | Should -Be 'present'
        $features.features.outlines.state | Should -Be 'present'
        $features.features.links.state | Should -Be 'present'
    }

    It 'creates a real image XObject that Poppler enumerates' {
        if (-not $pdfimages) {
            Set-ItResult -Skipped -Because 'pdfimages is not available'
            return
        }
        $path = Join-Path $TestDrive 'generated-raster.pdf'
        New-SyntheticPdf -OutputPath $path -IncludeRasterImage | Out-Null
        $lines = @(& $pdfimages '-list' '--' $path 2>&1)
        $LASTEXITCODE | Should -Be 0
        ($lines -join "`n") | Should -Match '(?m)^\s*1\s+0\s+image\s+120\s+160\s+'
    }

    It 'analyzes a generated high-DPI mixed text and raster document' {
        if (-not $pdfinfo -or -not $pdfimages) {
            Set-ItResult -Skipped -Because 'pdfinfo or pdfimages is not available'
            return
        }
        $path = Join-Path $TestDrive 'generated-high-dpi-mixed.pdf'
        New-SyntheticPdf -OutputPath $path -IncludeRasterImage -RasterWidth 1600 -RasterHeight 2000 | Out-Null
        $metrics = Get-PdfMetrics -PdfPath $path -PdfInfoExe $pdfinfo -PdfImagesExe $pdfimages
        $metrics.error | Should -BeNullOrEmpty
        $metrics.hasImages | Should -BeTrue
        $metrics.imageCount | Should -Be 1
        $metrics.avgDpi | Should -BeGreaterThan 220
    }

    It 'preserves generated mixed rotations and crop boxes in the real structure snapshot' {
        if (-not $pdfinfo) {
            Set-ItResult -Skipped -Because 'pdfinfo is not available'
            return
        }
        $path = Join-Path $TestDrive 'generated-crop-rotate.pdf'
        New-SyntheticPdf -OutputPath $path -PageCount 2 -RotationByPage @{ 2 = 90 } -CropBoxByPage @{ 2 = @(18, 24, 594, 768) } | Out-Null
        $snapshot = Get-PdfStructureSnapshot -PdfPath $path -PdfInfoExe $pdfinfo -QpdfExe $qpdf -PageCount 2
        $snapshot.status | Should -Be 'verified'
        @($snapshot.pages[1].crop_box) | Should -Be @(18,24,594,768)
        [int]$snapshot.pages[1].rotate | Should -Be 90
    }

    It 'detects a generated password-encrypted PDF without embedding production credentials' {
        if (-not $qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $plain = Join-Path $TestDrive 'generated-encryption-input.pdf'
        $encrypted = Join-Path $TestDrive 'generated-encrypted.pdf'
        New-SyntheticPdf -OutputPath $plain | Out-Null
        & $qpdf '--encrypt' '--user-password=fixture-user' '--owner-password=fixture-owner' '--bits=256' '--' $plain $encrypted
        $LASTEXITCODE | Should -Be 0
        $features = Get-PdfFeatures -PdfPath $encrypted -QpdfExe $qpdf
        $features.features.encrypted.state | Should -Be 'present'
        $features.warnings | Should -Contain 'encrypted-input'
    }

    It 'classifies a generated recoverable malformed xref as a real qpdf warning' {
        if (-not $qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $path = Join-Path $TestDrive 'generated-malformed-warning.pdf'
        New-SyntheticPdf -OutputPath $path | Out-Null
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::ASCII)
        $text = [regex]::Replace($text, 'startxref\r?\n\d+', "startxref`n1")
        [IO.File]::WriteAllText($path, $text, [Text.Encoding]::ASCII)
        $check = Invoke-QpdfCheck -QpdfExe $qpdf -PdfPath $path
        $check.status | Should -Be 'warning'
        $check.exit_code | Should -Be 3
        @($check.warnings).Count | Should -BeGreaterThan 0
    }

    It 'uses real candidate byte sizes for target met, not-met, and no-valid outcomes' {
        if (-not $qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $input = Join-Path $TestDrive 'generated-target-input.pdf'
        $candidate = Join-Path $TestDrive 'generated-target-candidate.pdf'
        New-SyntheticPdf -OutputPath $input -PageCount 4 -TargetBytes 1MB | Out-Null
        & $qpdf '--object-streams=generate' '--' $input $candidate
        $LASTEXITCODE | Should -Be 0
        $bytes = (Get-Item -LiteralPath $candidate).Length
        $record = [pscustomobject]@{ strategy_id = 'qpdf-lossless'; quality_rank = 1; valid = $true; bytes = $bytes; path = $candidate }
        (Select-BestTargetCandidate -Candidates @($record) -TargetBytes $bytes -OriginalBytes ((Get-Item -LiteralPath $input).Length)).target_status | Should -Be 'met'
        (Select-BestTargetCandidate -Candidates @($record) -TargetBytes 1 -OriginalBytes ((Get-Item -LiteralPath $input).Length)).target_status | Should -Be 'not-met'
        (Select-BestTargetCandidate -Candidates @([pscustomobject]@{ quality_rank = 1; valid = $false; bytes = 0 }) -TargetBytes 1 -OriginalBytes ((Get-Item -LiteralPath $input).Length)).target_status | Should -Be 'no-valid-candidate'
    }

    It 'reports an already optimized generated PDF as no-effect without formal output' {
        if (-not $qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $raw = Join-Path $TestDrive 'generated-no-effect-raw.pdf'
        $optimizedOnce = Join-Path $TestDrive 'generated-no-effect-once.pdf'
        $optimizedInput = Join-Path $TestDrive 'generated-no-effect-input.pdf'
        New-SyntheticPdf -OutputPath $raw -PageCount 3 -TargetBytes 1MB | Out-Null
        & $qpdf '--object-streams=generate' '--' $raw $optimizedOnce
        $LASTEXITCODE | Should -Be 0
        & $qpdf '--object-streams=generate' '--' $optimizedOnce $optimizedInput
        $LASTEXITCODE | Should -Be 0

        $outputRoot = Join-Path $projectRoot ("_work\e2e-no-effect-{0}" -f [Guid]::NewGuid().ToString('N'))
        $logPath = Join-Path $outputRoot 'generated-no-effect.jsonl'
        try {
            $pwshExe = (Get-Process -Id $PID).Path
            $statusOutput = & $pwshExe -NoProfile -File (Join-Path $internalRoot 'compress.ps1') `
                -InputPath $optimizedInput -OutputRoot $outputRoot -LogPath $logPath `
                -StrategyOverride 'qpdf-lossless' -SafetyMode Off -StatusJson 2>&1 | Out-String
            $childExitCode = $LASTEXITCODE

            $childExitCode | Should -Be 0
            $record = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $record.status | Should -Be 'skip'
            $record.fail_reason | Should -Be 'no-effect'
            [long]$record.compressed | Should -Be ([long]$record.original)
            @(Get-ChildItem -LiteralPath $outputRoot -Filter '*.pdf' -File -ErrorAction SilentlyContinue).Count | Should -Be 0
            $statusOutput | Should -Match 'no-effect'
        } finally {
            if (Test-Path -LiteralPath $outputRoot -PathType Container) {
                Remove-Item -LiteralPath $outputRoot -Recurse -Force
            }
        }
    }

    It 'accepts device-pixel page-box rounding for an explicitly selected raster strategy' {
        if (-not $qpdf -or -not $pdfinfo -or -not $ghostscript) {
            Set-ItResult -Skipped -Because 'qpdf, pdfinfo, or Ghostscript is not available'
            return
        }
        $input = Join-Path $TestDrive 'generated-fractional-a4.pdf'
        New-SyntheticPdf -OutputPath $input -MediaBox @(0, 0, 595.32, 841.92) -TargetBytes 2MB | Out-Null
        $outputRoot = Join-Path $projectRoot ("_work\e2e-fractional-a4-{0}" -f [Guid]::NewGuid().ToString('N'))
        $logPath = Join-Path $outputRoot 'fractional-a4.jsonl'
        try {
            $pwshExe = (Get-Process -Id $PID).Path
            & $pwshExe -NoProfile -File (Join-Path $internalRoot 'compress.ps1') `
                -InputPath $input -OutputRoot $outputRoot -LogPath $logPath `
                -StrategyOverride 'gs-raster-low-quality' -SafetyMode Safe `
                -AllowFullPageRaster -Force
            $LASTEXITCODE | Should -Be 0
            $record = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $record.status | Should -Be 'ok'
            $record.verification_status | Should -Be 'verified'
            @($record.verification_reasons).Count | Should -Be 0
            $record.strategy_id | Should -Be 'gs-raster-low-quality'
            Test-Path -LiteralPath (Join-Path $outputRoot 'generated-fractional-a4.compressed.pdf') | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $outputRoot -PathType Container) {
                Remove-Item -LiteralPath $outputRoot -Recurse -Force
            }
        }
    }

    It 'applies Safe/Warn/Off feature actions to the policy model' {
        $features = [pscustomobject]@{ features = [pscustomobject]@{
            digital_signature = [pscustomobject]@{ state = 'absent' }
            encrypted = [pscustomobject]@{ state = 'absent' }
            acroform = [pscustomobject]@{ state = 'present' }
            tagged = [pscustomobject]@{ state = 'present' }
            javascript = [pscustomobject]@{ state = 'present' }
            layers = [pscustomobject]@{ state = 'present' }
            attachments = [pscustomobject]@{ state = 'present' }
            pdfa = [pscustomobject]@{ state = 'present' }
            pdfx = [pscustomobject]@{ state = 'present' }
        } }
        (Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'qpdf-lossless').warnings.Count | Should -BeGreaterThan 0
        (Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'gs-raster-readable' -AllowFullPageRaster).action | Should -Be 'skip'
        (Get-SafetyDecision -Features $features -SafetyMode Off -StrategyId 'qpdf-lossless').action | Should -Be 'continue'
    }

    It 'keeps the six Phase 5 strategy IDs visible while filtering unavailable tools' {
        $metrics = [pscustomobject]@{ hasImages = $false; imageRatio = 0.0; avgDpi = $null; pageCount = 1 }
        $capabilities = [pscustomobject]@{ entries = [pscustomobject]@{
            qpdf = [pscustomobject]@{ found = $true; path = 'qpdf' }
            ghostscript = [pscustomobject]@{ found = $false; path = $null }
        } }
        $plan = Get-ModeStrategyPlan -Mode 'minimum-size' -Metrics $metrics -Strategies $strategies -Capabilities $capabilities
        @($plan.strategy_id) | Should -Contain 'qpdf-lossless'
        @($plan.strategy_id) | Should -Not -Contain 'gs-downsample-120'
        $allIds = @('qpdf-lossless','gs-downsample-150','gs-downsample-180','gs-light-regenerate','gs-raster-low-quality','gs-raster-readable')
        @($allIds).Count | Should -Be 6
    }
}
