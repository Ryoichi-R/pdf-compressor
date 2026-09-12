# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    pdf-compressor CLI orchestrator.

.DESCRIPTION
    Creates or reads an input manifest, performs per-item preflight and safety
    checks, generates candidates in _work, validates syntax and page structure,
    then moves only an accepted candidate to the formal output path.

    Existing InputPath/InputPathFile, StrategyOverride, JSONL, StatusJson,
    output naming, and exit codes 0..5 remain compatible. Exit code 6 is used
    when an operator action is required (safety skip or unmet target).
#>

[CmdletBinding()]
param(
    [string]$InputPath,
    [string]$InputPathFile,
    [string]$InputManifest,
    [switch]$Force,
    [string]$LogPath,
    [string]$OutputRoot,
    # Backward-compatible strategy contract (legacy order):
    # ValidateSet('auto','qpdf-lossless','gs-downsample-150','gs-downsample-180','gs-light-regenerate','gs-raster-low-quality','gs-raster-readable')
    [ValidateSet('auto','qpdf-lossless','gs-downsample-120','gs-downsample-150','gs-downsample-180','gs-light-regenerate','gs-raster-low-quality','gs-raster-readable')]
    [string]$StrategyOverride = 'auto',
    [ValidateSet('auto','high-quality','standard','minimum-size')]
    [string]$Mode = 'auto',
    [ValidateSet('Safe','Warn','Off')]
    [string]$SafetyMode = 'Safe',
    [Nullable[long]]$TargetBytes,
    [switch]$EnableOcr,
    [string[]]$OcrLanguages = @(),
    [switch]$AllowSignedPdf,
    [switch]$AllowFullPageRaster,
    [switch]$AllowReducedVerification,
    [switch]$AcceptManifestRiskConsents,
    [string]$RiskConsentNonce,
    [string]$CancelFile,
    [switch]$StatusJson,
    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:ScriptDir = $PSScriptRoot
$script:ToolRoot = Split-Path -Parent $script:ScriptDir
$script:DefaultOutputRoot = Join-Path $script:ToolRoot 'output'
$script:ResolvedOutputRoot = $script:DefaultOutputRoot
$script:LogPathDefault = Join-Path $script:DefaultOutputRoot 'compress.log.jsonl'
$script:UseOutsideOutputRoot = $false
$script:WorkRoot = Join-Path $script:ToolRoot '_work'
$script:DataDir = Join-Path $script:ScriptDir 'data'
$script:StrategiesPath = Join-Path $script:DataDir 'strategies.json'
$script:ToolPathsFile = Join-Path $script:DataDir 'tool-paths.json'
$script:CurrentCapabilities = $null

. (Join-Path $script:ScriptDir 'path-guard.ps1')
. (Join-Path $script:ScriptDir 'output-path.ps1')
. (Join-Path $script:ScriptDir 'output-transaction.ps1')
. (Join-Path $script:ScriptDir 'log-format.ps1')
. (Join-Path $script:ScriptDir 'work-dir.ps1')
. (Join-Path $script:ScriptDir 'tool-resolver.ps1')
. (Join-Path $script:ScriptDir 'tool-capabilities.ps1')
. (Join-Path $script:ScriptDir 'input-manifest.ps1')
. (Join-Path $script:ScriptDir 'jsonl-writer.ps1')
. (Join-Path $script:ScriptDir 'analyze_pdf.ps1')
. (Join-Path $script:ScriptDir 'select_strategy.ps1')
. (Join-Path $script:ScriptDir 'invoke_ghostscript.ps1')
. (Join-Path $script:ScriptDir 'invoke_lossy_raster.ps1')
. (Join-Path $script:ScriptDir 'invoke_qpdf.ps1')
. (Join-Path $script:ScriptDir 'pdf-structure.ps1')
. (Join-Path $script:ScriptDir 'inspect_pdf_features.ps1')
. (Join-Path $script:ScriptDir 'safety-policy.ps1')
. (Join-Path $script:ScriptDir 'validate_output.ps1')
. (Join-Path $script:ScriptDir 'target-size.ps1')
. (Join-Path $script:ScriptDir 'ocr-provider.ps1')

function Get-OptionalProperty {
    param([object]$Object,[Parameter(Mandatory)][string]$Name,[object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable] -and $Object.ContainsKey($Name)) { return $Object[$Name] }
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-ResolvedTools {
    <# Compatibility wrapper. Capability discovery never exits from inside the helper. #>
    # Find-ToolExecutable -Name is the shared resolver used by the capability model.
    $cap = Get-ToolCapabilities -CachePath $script:ToolPathsFile
    $script:CurrentCapabilities = $cap
    $paths = $cap.paths
    $payload = [ordered]@{
        ghostscript = Get-OptionalProperty $paths 'ghostscript'
        qpdf = Get-OptionalProperty $paths 'qpdf'
        pdfinfo = Get-OptionalProperty $paths 'pdfinfo'
        pdfimages = Get-OptionalProperty $paths 'pdfimages'
        pdfdetach = Get-OptionalProperty $paths 'pdfdetach'
        pdfsig = Get-OptionalProperty $paths 'pdfsig'
        ocrmypdf = Get-OptionalProperty $paths 'ocrmypdf'
        capabilities = $cap
    }
    # Persist paths for the next launch, but cache failure is non-fatal.
    try {
        Assert-WritePathInsideTool -TargetPath $script:ToolPathsFile | Out-Null
        [ordered]@{ ghostscript=$payload.ghostscript; qpdf=$payload.qpdf; pdfinfo=$payload.pdfinfo; pdfimages=$payload.pdfimages; pdfdetach=$payload.pdfdetach; pdfsig=$payload.pdfsig; ocrmypdf=$payload.ocrmypdf } |
            ConvertTo-Json | Set-Content -LiteralPath $script:ToolPathsFile -Encoding UTF8
    } catch {}
    return [pscustomobject]$payload
}

function Test-WorkDirOwnerAlive {
    param([Parameter(Mandatory)][string]$DirName)
    return Test-WorkDirOwnerAliveCore -DirName $DirName
}

function Invoke-WorkDirCleanup {
    # Kept as a zero-argument compatibility function for existing tests.
    Invoke-WorkDirCleanupCore -WorkRoot $script:WorkRoot
}

function Get-ResultProperty {
    param([object]$Object,[string]$Name,[object]$Default = $null)
    return Get-OptionalProperty -Object $Object -Name $Name -Default $Default
}

function Invoke-CompressOne {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Pdf,
        [Parameter(Mandatory)][object]$Tools,
        [Parameter(Mandatory)][object]$Strategies,
        [object]$Item,
        [object]$OutputContext,
        [object]$Capabilities,
        [ValidateSet('auto','high-quality','standard','minimum-size')][string]$ItemMode = $Mode,
        [ValidateSet('Safe','Warn','Off')][string]$ItemSafetyMode = $SafetyMode,
        [Nullable[long]]$ItemTargetBytes = $TargetBytes,
        [bool]$ItemEnableOcr = [bool]$EnableOcr,
        [string[]]$ItemOcrLanguages = $OcrLanguages,
        [switch]$ItemAllowSignedPdf = $AllowSignedPdf,
        [switch]$ItemAllowFullPageRaster = $AllowFullPageRaster,
        [switch]$ItemAllowReducedVerification = $AllowReducedVerification,
        [switch]$ItemForce = $Force,
        [switch]$ItemPreflightOnly = $PreflightOnly,
        [string]$ItemCancelFile = $CancelFile
    )
    $cancelEffective = $ItemCancelFile
    $itemId = [string](Get-ResultProperty $Item 'item_id' ([Guid]::NewGuid().ToString('N')))
    $modeEffective = [string](Get-ResultProperty $Item 'mode' $ItemMode)
    if ([string]::IsNullOrWhiteSpace($modeEffective)) { $modeEffective = $ItemMode }
    $safetyEffective = [string](Get-ResultProperty $Item 'safety_mode' $ItemSafetyMode)
    if ([string]::IsNullOrWhiteSpace($safetyEffective)) { $safetyEffective = $ItemSafetyMode }
    $itemTargetValue = Get-ResultProperty $Item 'target_bytes'
    $targetEffective = if ($null -ne $itemTargetValue -and (Test-TargetBytes -TargetBytes $itemTargetValue)) { $itemTargetValue } else { $ItemTargetBytes }
    $allowSigned = [bool](Get-ResultProperty $Item 'allow_signed_pdf' ([bool]$ItemAllowSignedPdf))
    $allowRaster = [bool](Get-ResultProperty $Item 'allow_full_page_raster' ([bool]$ItemAllowFullPageRaster))
    $result = [ordered]@{
        item_id = $itemId; file = $Pdf.FullName; status = 'fail'; strategy_id = $null; tool = $null
        original = [long]$Pdf.Length; compressed = 0L; ratio_pct = 0; fail_reason = $null; warnings = @()
        mode = $modeEffective; safety_mode = $safetyEffective; features = $null; selection_reason = $null
        verification_status = 'not-run'; verification_reasons = @(); target_bytes = if ($targetEffective) { [long]$targetEffective } else { $null }
        target_status = 'not-requested'
        target_met = $null; attempt_count = 0; stop_reason = $null; ocr_status = if ($ItemEnableOcr) { 'pending' } else { 'disabled' }
        policy_reason = $null; output_path = $null
    }
    $originalSize = [long]$Pdf.Length

    try { $metrics = Get-PdfMetrics -PdfPath $Pdf.FullName -PdfInfoExe ([string](Get-ResultProperty $Tools 'pdfinfo')) -PdfImagesExe ([string](Get-ResultProperty $Tools 'pdfimages')) }
    catch {
        $result.fail_reason = 'analyze-exception'; $result.tool = 'analyze'; $result.warnings = @($_.Exception.Message); return [pscustomobject]$result
    }
    if ($metrics.error) { $result.fail_reason = $metrics.error; $result.tool = $metrics.tool; return [pscustomobject]$result }

    $qpdfPath = [string](Get-ResultProperty $Tools 'qpdf')
    $pdfinfoPath = [string](Get-ResultProperty $Tools 'pdfinfo')
    $useVerification = (-not [string]::IsNullOrWhiteSpace($qpdfPath) -and (Test-Path -LiteralPath $qpdfPath))
    $preflightStructure = $null; $preflightFeatures = $null
    if ($useVerification -and -not [string]::IsNullOrWhiteSpace($pdfinfoPath) -and (Test-Path -LiteralPath $pdfinfoPath)) {
        $preflightStructure = Get-PdfStructureSnapshot -PdfPath $Pdf.FullName -PdfInfoExe $pdfinfoPath -QpdfExe $qpdfPath -PageCount ([int]$metrics.pageCount)
        $preflightFeatures = Get-PdfFeatures -PdfPath $Pdf.FullName -QpdfExe $qpdfPath -PdfSigExe ([string](Get-ResultProperty $Tools 'pdfsig')) -PdfDetachExe ([string](Get-ResultProperty $Tools 'pdfdetach'))
        $result.features = $preflightFeatures.features
        $result.verification_status = if ($preflightStructure.status -eq 'verified') { 'verified' } else { 'indeterminate' }
    }

    $cap = if ($Capabilities) { $Capabilities } else { Get-ResultProperty $Tools 'capabilities' }
    $selection = $null
    if ($StrategyOverride -and $StrategyOverride -ne 'auto') {
        $selection = [pscustomobject]@{ strategy_id = $StrategyOverride; reason = 'explicit-strategy-override'; fallback = $null }
    } else {
        $selection = Select-CompressionStrategy -Metrics $metrics -Strategies $Strategies
    }
    $result.selection_reason = if ($selection.reason) { [string]$selection.reason } else { 'mode-policy' }
    if ($ItemPreflightOnly) {
        $result.strategy_id = if ($selection.strategy_id) { [string]$selection.strategy_id } else { $null }
        $decision = $null
        if ($preflightFeatures -and $result.strategy_id) {
            $decision = Get-SafetyDecision -Features $preflightFeatures -SafetyMode $safetyEffective -StrategyId ([string]$result.strategy_id) -AllowSignedPdf:$allowSigned -AllowFullPageRaster:$allowRaster -AllowReducedVerification:$ItemAllowReducedVerification
            $result.policy_reason = $decision.policy_reason
            $result.verification_status = $decision.verification_status
            $result.verification_reasons = @($decision.reasons)
            $result.warnings = @($decision.warnings)
        }
        $result.status = 'skip'
        $result.fail_reason = 'preflight-only'
        $result.tool = 'preflight'
        $result.analysis = [ordered]@{
            status = if ($preflightStructure -and $preflightStructure.status) { [string]$preflightStructure.status } else { 'unavailable' }
            page_count = [int]$metrics.pageCount
            image_ratio = [double]$metrics.imageRatio
            avg_dpi = if ($null -ne $metrics.avgDpi) { [double]$metrics.avgDpi } else { $null }
            has_images = [bool]$metrics.hasImages
            selection_reason = [string]$result.selection_reason
            strategy_id = $result.strategy_id
            verification_status = [string]$result.verification_status
            verification_reasons = @($result.verification_reasons)
            safety_action = if ($decision) { [string]$decision.action } else { 'unavailable' }
            policy_reason = if ($result.policy_reason) { [string]$result.policy_reason } else { 'verification-unavailable' }
            features = $result.features
            warnings = @($result.warnings)
        }
        return [pscustomobject]$result
    }
    $candidateIds = @()
    if ($StrategyOverride -and $StrategyOverride -ne 'auto') { $candidateIds = @($StrategyOverride) }
    elseif ($modeEffective -eq 'auto' -and $targetEffective) {
        # A target request needs a bounded quality-to-size ladder. The ladder
        # is defined by modes.json (minimum-size), not by a second hardcoded
        # list in the orchestrator.
        $targetPlan = Get-StrategyCandidates -Mode 'minimum-size' -Metrics $metrics -Strategies $Strategies -Capabilities $cap -AllowFullPageRaster:$allowRaster
        $candidateIds = @($targetPlan | ForEach-Object { [string]$_.strategy_id })
    }
    elseif ($modeEffective -eq 'auto') { $candidateIds = @($selection.strategy_id); if ($selection.fallback) { $candidateIds += [string]$selection.fallback } }
    else {
        $plan = Get-ModeStrategyPlan -Mode $modeEffective -Metrics $metrics -Strategies $Strategies -Capabilities $cap -AllowFullPageRaster:$allowRaster
        $candidateIds = @($plan | ForEach-Object { $_.strategy_id })
    }
    if ($candidateIds.Count -eq 0) { $result.fail_reason = 'tool-unavailable'; $result.stop_reason = 'tool-unavailable'; return [pscustomobject]$result }

    $outputPath = if ($OutputContext) {
        $seen = $OutputContext.seen_map
        $resolved = Resolve-OutputPath -Pdf $Pdf -Context $OutputContext -SeenMap ([ref]$seen)
        $OutputContext.seen_map = $seen
        $resolved
    } else {
        $legacyContext = New-OutputPathContext -SourceRoot $Pdf.DirectoryName -OutputRoot $script:ResolvedOutputRoot -UseOutsideOutputRoot $script:UseOutsideOutputRoot
        $legacySeen = @{}
        Resolve-OutputPath -Pdf $Pdf -Context $legacyContext -SeenMap ([ref]$legacySeen)
    }
    $result.output_path = $outputPath
    $outputDir = Split-Path -Parent $outputPath
    if (-not (Test-Path -LiteralPath $outputDir)) {
        if ($OutputContext -and $OutputContext.use_outside_output_root) { Assert-OutputPathLocal -TargetPath $outputDir | Out-Null }
        else { Assert-WritePathInsideTool -TargetPath $outputDir | Out-Null }
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $recovery = Restore-PendingOutputTransaction -OutputPath $outputPath
    if ($recovery.status -eq 'restored') { Write-Host "[RECOVERY] restored previous output: $outputPath" -ForegroundColor Yellow }
    if ((Test-Path -LiteralPath $outputPath) -and (-not $ItemForce)) {
        $result.status = 'skip'; $result.fail_reason = 'exists'; $result.compressed = (Get-Item -LiteralPath $outputPath).Length; return [pscustomobject]$result
    }

    $work = New-WorkSubdirectory -WorkRoot $script:WorkRoot
    $tmpOut = Join-Path $work 'out.pdf'
    Assert-WritePathInsideTool -TargetPath $tmpOut | Out-Null
    $validCandidates = @()
    $lastErr = $null
    $attemptIndex = 0
    try {
        # Legacy equivalent: foreach ($sid in $attempts). Candidate IDs are now
        # produced by mode/target policy and are bounded to seven attempts.
        foreach ($sid in $candidateIds | Select-Object -First 7) {
            if ($cancelEffective -and (Test-Path -LiteralPath $cancelEffective -PathType Leaf)) {
                $result.status = 'fail'; $result.fail_reason = 'aborted'; $result.stop_reason = 'aborted'; return [pscustomobject]$result
            }
            $attemptIndex++
            $result.attempt_count = $attemptIndex
            $stratDef = Get-StrategyById -Config $Strategies -Id ([string]$sid)
            if ($cap) {
                $capResult = Test-StrategyCapability -Capabilities $cap -StrategyId ([string]$sid)
                if (-not $capResult.available) { $lastErr = @{ tool = $capResult.capability; reason = 'tool-unavailable' }; continue }
            }
            if ($preflightFeatures) {
                $decision = Get-SafetyDecision -Features $preflightFeatures -SafetyMode $safetyEffective -StrategyId ([string]$sid) -AllowSignedPdf:$allowSigned -AllowFullPageRaster:$allowRaster -AllowReducedVerification:$ItemAllowReducedVerification
                $result.policy_reason = $decision.policy_reason
                $result.verification_status = $decision.verification_status
                $result.verification_reasons = @($decision.reasons)
                $result.warnings = @($decision.warnings)
                if ($decision.action -in @('skip','confirm','unavailable')) {
                    $result.status = 'skip'; $result.fail_reason = 'safety-skip'; $result.stop_reason = 'safety-skip'; return [pscustomobject]$result
                }
            } elseif ($safetyEffective -eq 'Safe' -and $useVerification -eq $false -and $cap) {
                $lastErr = @{ tool = 'qpdf'; reason = 'tool-unavailable' }; continue
            }
            $stratTool = [string]$stratDef.tool
            $invRes = $null
            $structureBoxTolerance = [decimal]0.01
            $allowedDpi = @($Strategies.allowed_dpi | ForEach-Object { [int]$_ })
            if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
            switch ($stratTool) {
                'qpdf' { $invRes = Invoke-Qpdf -QpdfExe ([string](Get-ResultProperty $Tools 'qpdf')) -InputPdf $Pdf.FullName -OutputPdf $tmpOut }
                'ghostscript' {
                    $invRes = Invoke-Ghostscript -GhostscriptExe ([string](Get-ResultProperty $Tools 'ghostscript')) -InputPdf $Pdf.FullName -OutputPdf $tmpOut -ColorDpi ([int]$stratDef.params.color_dpi) -GrayDpi ([int]$stratDef.params.gray_dpi) -AllowedDpi $allowedDpi
                }
                'lossy-raster' {
                    $rasterDpi = [int]$stratDef.params.raster_dpi
                    # pdfimage24 quantizes page edges to device pixels. Permit at
                    # most one device pixel while retaining exact checks for all
                    # non-raster strategies and rejecting material CropBox loss.
                    $structureBoxTolerance = [decimal](72.0 / [double]$rasterDpi)
                    $invRes = Invoke-LossyRaster -GhostscriptExe ([string](Get-ResultProperty $Tools 'ghostscript')) -InputPdf $Pdf.FullName -OutputPdf $tmpOut -RasterDpi $rasterDpi -JpegQuality ([int]$stratDef.params.jpeg_quality)
                }
                default { $lastErr = @{ tool = $stratTool; reason = 'unknown-tool' }; continue }
            }
            if ($cancelEffective -and (Test-Path -LiteralPath $cancelEffective -PathType Leaf)) {
                $result.status = 'fail'; $result.fail_reason = 'aborted'; $result.stop_reason = 'aborted'; return [pscustomobject]$result
            }
            if (-not $invRes.success) { $lastErr = @{ tool = $invRes.tool; reason = 'tool-crashed'; rc = $invRes.exitCode }; continue }
            if (-not (Test-Path -LiteralPath $tmpOut -PathType Leaf)) { $lastErr = @{ tool = $stratTool; reason = 'output-missing' }; continue }
            $newSize = [long](Get-Item -LiteralPath $tmpOut).Length
            if ($newSize -ge $originalSize) { $lastErr = @{ tool = $invRes.tool; reason = 'output-too-large'; rc = 0 }; continue }

            $validation = $null
            if ($useVerification) {
                $afterStructure = Get-PdfStructureSnapshot -PdfPath $tmpOut -PdfInfoExe $pdfinfoPath -QpdfExe $qpdfPath -PageCount ([int]$metrics.pageCount)
                $afterFeatures = Get-PdfFeatures -PdfPath $tmpOut -QpdfExe $qpdfPath -PdfSigExe ([string](Get-ResultProperty $Tools 'pdfsig')) -PdfDetachExe ([string](Get-ResultProperty $Tools 'pdfdetach'))
                $validation = Validate-CompressedPdf -InputPdf $Pdf.FullName -CandidatePdf $tmpOut -QpdfExe $qpdfPath -PdfInfoExe $pdfinfoPath -BeforeStructure $preflightStructure -AfterStructure $afterStructure -BeforeFeatures $preflightFeatures -AfterFeatures $afterFeatures -SafetyMode $safetyEffective -StructureBoxTolerance $structureBoxTolerance
                $result.verification_status = $validation.status
                $result.verification_reasons = @($validation.reasons)
                if (-not $validation.accepted) { $lastErr = @{ tool = 'validation'; reason = 'validation-rejected' }; continue }
            }
            $candidatePath = $tmpOut
            if ($targetEffective) {
                $candidatePath = Join-Path $work ("candidate-{0}.pdf" -f $attemptIndex)
                Copy-Item -LiteralPath $tmpOut -Destination $candidatePath -Force
            }
            $validCandidates += [pscustomobject]@{ valid = $true; bytes = $newSize; quality_rank = $attemptIndex; strategy_id = [string]$sid; path = $candidatePath; validation = $validation; tool = $invRes.tool }
            if (-not $targetEffective) { break }
        }

        $chosen = $null
        if ($targetEffective) {
            if ($validCandidates.Count -eq 0) {
                $result.target_status = 'not-met'
                $result.target_met = $false
                $result.stop_reason = 'target-no-valid-candidate'
                $result.fail_reason = 'no-valid-candidate'
                return [pscustomobject]$result
            }
            $targetResult = Select-BestTargetCandidate -Candidates $validCandidates -TargetBytes ([long]$targetEffective) -OriginalBytes $originalSize -MaxAttempts 7
            $result.target_status = $targetResult.target_status
            $result.target_met = $targetResult.target_met
            $result.stop_reason = $targetResult.stop_reason
            if ($targetResult.selected) { $chosen = $targetResult.selected; $tmpOut = $chosen.path; $result.strategy_id = $chosen.strategy_id; $result.tool = $chosen.tool; $result.compressed = [long]$chosen.bytes }
            else { $result.fail_reason = 'no-valid-candidate'; return [pscustomobject]$result }
        } elseif ($validCandidates.Count -gt 0) {
            $chosen = $validCandidates[0]; $result.strategy_id = $chosen.strategy_id; $result.tool = $chosen.tool; $result.compressed = [long]$chosen.bytes
        }
        if ($null -eq $chosen) {
            if ($lastErr -and $lastErr.reason -eq 'output-too-large') { $result.status = 'skip'; $result.fail_reason = 'no-effect'; $result.compressed = $originalSize; return [pscustomobject]$result }
            $result.status = 'fail'; $result.fail_reason = if ($lastErr) { $lastErr.reason } else { 'unknown' }; $result.tool = if ($lastErr) { $lastErr.tool } else { 'compression' }; return [pscustomobject]$result
        }

        if ($ItemEnableOcr) {
            $ocrCaps = Get-OcrCapabilities -Capabilities $cap
            $ocrTemp = Join-Path $work 'ocr.pdf'
            $ocrRun = Invoke-OcrProvider -OcrCapabilities $ocrCaps -InputPdf $tmpOut -OutputPdf $ocrTemp -Languages $ItemOcrLanguages -Mode 'skip'
            if (-not $ocrRun.success) { $result.ocr_status = if ($ocrRun.status -eq 'unavailable') { 'skipped' } else { 'fail' }; $result.fail_reason = 'ocr-unavailable'; $result.stop_reason = 'ocr-unavailable'; return [pscustomobject]$result }
            $result.ocr_status = 'applied'
            $ocrValidation = Validate-CompressedPdf -InputPdf $Pdf.FullName -CandidatePdf $ocrTemp -QpdfExe $qpdfPath -PdfInfoExe $pdfinfoPath -BeforeStructure $preflightStructure -AfterStructure (Get-PdfStructureSnapshot -PdfPath $ocrTemp -PdfInfoExe $pdfinfoPath -QpdfExe $qpdfPath -PageCount ([int]$metrics.pageCount)) -BeforeFeatures $preflightFeatures -AfterFeatures (Get-PdfFeatures -PdfPath $ocrTemp -QpdfExe $qpdfPath) -SafetyMode $safetyEffective
            if (-not $ocrValidation.accepted) { $result.fail_reason = 'validation-rejected'; $result.verification_status = $ocrValidation.status; $result.verification_reasons = @($ocrValidation.reasons); return [pscustomobject]$result }
            $tmpOut = $ocrTemp; $result.compressed = [long](Get-Item -LiteralPath $tmpOut).Length
        }

        # Formal output is touched only after candidate validation succeeded.
        if ($cancelEffective -and (Test-Path -LiteralPath $cancelEffective -PathType Leaf)) {
            $result.status = 'fail'; $result.fail_reason = 'aborted'; $result.stop_reason = 'aborted'; return [pscustomobject]$result
        }
        Invoke-OutputTransaction -CandidatePath $tmpOut -OutputPath $outputPath -ReplaceExisting:$ItemForce
        $result.status = 'ok'
        if ($result.compressed -le 0) { $result.compressed = [long](Get-Item -LiteralPath $outputPath).Length }
        if ($originalSize -gt 0) { $result.ratio_pct = [int][math]::Round(($result.compressed - $originalSize) * 100.0 / $originalSize) }
        if ($result.stop_reason -eq 'target-not-met') { $result.status = 'ok' }
        return [pscustomobject]$result
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-StatusJsonLine {
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Payload)
    if (-not $StatusJson) { return }
    Write-Host ("##STATUS## " + ($Payload | ConvertTo-Json -Compress -Depth 8))
}

function Write-ResultLine {
    param([Parameter(Mandatory)][object]$Res,[Parameter(Mandatory)][string]$Jsonl,[int]$Index = 0,[bool]$EmitStatusJson = [bool]$StatusJson)
    $name = Split-Path -Leaf $Res.file
    $origStr = Format-Size -Bytes ([long]$Res.original)
    switch ($Res.status) {
        'ok' { Write-Host ("[OK] {0}  {1} -> {2}  ({3}%)  strategy={4}" -f $name,$origStr,(Format-Size -Bytes ([long]$Res.compressed)),[int]$Res.ratio_pct,$Res.strategy_id) }
        'skip' { Write-Host ("[SKIP] {0}  {1} -> {2}  {3}" -f $name,$origStr,(Format-Size -Bytes ([long]$Res.compressed)),$Res.fail_reason) }
        'fail' {
            Write-Host ("[FAIL] {0}  tool={1} fail_reason={2}" -f $name,$Res.tool,$Res.fail_reason) -ForegroundColor Red
            foreach ($reason in @($Res.verification_reasons)) { Write-Host ("       verification_reason={0}" -f $reason) -ForegroundColor DarkYellow }
            foreach ($w in @($Res.warnings)) { Write-Host ("       {0}" -f $w) -ForegroundColor DarkYellow }
        }
    }
    $record = ConvertTo-JsonlResultRecord -Result $Res
    Write-JsonlRecord -Path $Jsonl -Record $record
    if ($EmitStatusJson) {
        $evt = [ordered]@{ event='file'; idx=[int]$Index; file=$Res.file; item_id=$Res.item_id; status=$Res.status; strategy_id=$Res.strategy_id; original=[long]$Res.original; compressed=[long]$Res.compressed; ratio_pct=[int]$Res.ratio_pct; fail_reason=$Res.fail_reason; tool=$Res.tool; verification_status=$Res.verification_status; verification_reasons=@($Res.verification_reasons); target_status=$Res.target_status; target_met=$Res.target_met; stop_reason=$Res.stop_reason; ocr_status=$Res.ocr_status; output_path=$Res.output_path; policy_reason=$Res.policy_reason }
        Write-Host ("##STATUS## " + ($evt | ConvertTo-Json -Compress))
    }
}

function Invoke-PdfCompressorMain {
    [CmdletBinding()]
    param(
        [string]$InputPath,
        [string]$InputPathFile,
        [string]$InputManifest,
        [switch]$Force,
        [string]$LogPath,
        [string]$OutputRoot,
        [ValidateSet('auto','qpdf-lossless','gs-downsample-120','gs-downsample-150','gs-downsample-180','gs-light-regenerate','gs-raster-low-quality','gs-raster-readable')]
        [string]$StrategyOverride = 'auto',
        [ValidateSet('auto','high-quality','standard','minimum-size')][string]$Mode = 'auto',
        [ValidateSet('Safe','Warn','Off')][string]$SafetyMode = 'Safe',
        [Nullable[long]]$TargetBytes,
        [switch]$EnableOcr,
        [string[]]$OcrLanguages = @(),
        [switch]$AllowSignedPdf,
        [switch]$AllowFullPageRaster,
        [switch]$AllowReducedVerification,
        [switch]$AcceptManifestRiskConsents,
        [string]$RiskConsentNonce,
        [string]$CancelFile,
        [switch]$StatusJson,
        [switch]$PreflightOnly
    )
try {
    if ($PSBoundParameters.ContainsKey('StrategyOverride') -and $StrategyOverride -eq 'auto') {
        Write-Host '[WARN] -StrategyOverride auto is deprecated; omit the parameter and use -Mode for policy selection.' -ForegroundColor DarkYellow
    }
    if (($InputPath -and $InputManifest) -or ($InputPathFile -and $InputManifest) -or ($InputPath -and $InputPathFile)) { Write-Host '[ERROR] InputPath, InputPathFile, and InputManifest are mutually exclusive.'; return 3 }
    if ($InputPathFile) {
        Assert-WritePathInsideTool -TargetPath $InputPathFile | Out-Null
        if (-not (Test-Path -LiteralPath $InputPathFile -PathType Leaf)) { Write-Host "[ERROR] Input path file not found: $InputPathFile" -ForegroundColor Red; return 3 }
        $InputPath = (Get-Content -LiteralPath $InputPathFile -Raw -Encoding UTF8).TrimEnd("`r","`n")
    }
    if ($InputManifest) {
        $manifest = Read-InputManifest -Path $InputManifest -AllowRiskConsents:$AcceptManifestRiskConsents -WorkRoot $script:WorkRoot -ConsentNonce $RiskConsentNonce
    } else {
        if ([string]::IsNullOrWhiteSpace($InputPath)) { Write-Host '[ERROR] Input path is required.'; return 3 }
        $manifest = New-InputManifestFromPath -InputPath $InputPath -Mode $Mode -SafetyMode $SafetyMode -TargetBytes $TargetBytes -EnableOcr:$EnableOcr -OcrLanguages $OcrLanguages -AllowSignedPdf:$AllowSignedPdf -AllowFullPageRaster:$AllowFullPageRaster
    }
    if ($manifest.items.Count -eq 0) {
        Write-Host '[INFO] No PDFs found in input.'
        if ($StatusJson) { Write-StatusJsonLine -Payload ([ordered]@{ event='start'; total=0 }); Write-StatusJsonLine -Payload ([ordered]@{ event='summary'; total=0; ok=0; skip=0; fail=0; exists=0; action_required=0; skip_ratio=0 }) }
        return 0
    }

    if ($PSBoundParameters.ContainsKey('OutputRoot') -and -not [string]::IsNullOrWhiteSpace($OutputRoot)) {
        $script:ResolvedOutputRoot = Assert-OutputPathLocal -TargetPath $OutputRoot
        $script:UseOutsideOutputRoot = ($script:ResolvedOutputRoot.TrimEnd('\').ToLowerInvariant() -ne $script:DefaultOutputRoot.TrimEnd('\').ToLowerInvariant())
    } else { $script:ResolvedOutputRoot = $script:DefaultOutputRoot; $script:UseOutsideOutputRoot = $false }
    if (-not (Test-Path -LiteralPath $script:ResolvedOutputRoot)) {
        if ($script:UseOutsideOutputRoot) { Assert-OutputPathLocal -TargetPath $script:ResolvedOutputRoot | Out-Null } else { Assert-WritePathInsideTool -TargetPath $script:ResolvedOutputRoot | Out-Null }
        New-Item -ItemType Directory -Path $script:ResolvedOutputRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:WorkRoot)) { Assert-WritePathInsideTool -TargetPath $script:WorkRoot | Out-Null; New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null }
    if ($CancelFile) {
        Assert-WritePathInsideTool -TargetPath $CancelFile | Out-Null
        $cancelFull = [IO.Path]::GetFullPath($CancelFile)
        if (-not $cancelFull.StartsWith([IO.Path]::GetFullPath($script:WorkRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'CancelFile must be under the owned work root.' }
    }
    Invoke-WorkDirCleanup
    if (-not $LogPath) { $LogPath = $script:LogPathDefault }
    Assert-WritePathInsideTool -TargetPath $LogPath | Out-Null
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { Assert-WritePathInsideTool -TargetPath $logDir | Out-Null; New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $LogPath)) { New-Item -ItemType File -Path $LogPath -Force | Out-Null }

    $tools = Get-ResolvedTools
    $missing = @($tools.capabilities.missing_required)
    if ($missing.Count -gt 0) { Write-Host "[ERROR] Missing required tools: $($missing -join ', '). Run install.bat or diagnostics." -ForegroundColor Red; return 2 }
    $script:Strategies = Get-Strategies -JsonPath $script:StrategiesPath
    $strategies = $script:Strategies
    if ($StatusJson) { Write-StatusJsonLine -Payload ([ordered]@{ event='diagnostic'; safe_ready=$tools.capabilities.safe_ready; missing_required=@($missing) }); Write-StatusJsonLine -Payload ([ordered]@{ event='start'; total=$manifest.items.Count }); Write-StatusJsonLine -Payload ([ordered]@{ event='queue'; total=$manifest.items.Count }) }
    $okN=0; $skipN=0; $failN=0; $existsN=0; $actionN=0; $idx=0; $stopReasons=@{}; $runSeenMap=@{}
    foreach ($item in @($manifest.items)) {
        if ($CancelFile -and (Test-Path -LiteralPath $CancelFile -PathType Leaf)) {
            Write-Host '[ABORTED] cooperative cancel requested' -ForegroundColor Yellow
            if ($StatusJson) { Write-StatusJsonLine -Payload ([ordered]@{ event='aborted'; reason='cancel-marker'; file=[string]$item.input_path }) }
            return 1
        }
        $idx++
        $file = Get-Item -LiteralPath $item.input_path -Force -ErrorAction Stop
        if ($StatusJson) { Write-StatusJsonLine -Payload ([ordered]@{ event='file-start'; idx=$idx; file=$file.FullName }) }
        $sourceRoot = if ($file.PSIsContainer) { $file.FullName } else { $file.DirectoryName }
        $itemOutput = Get-OptionalProperty $item 'output_root'
        $effectiveOutput = if ($itemOutput) { Assert-OutputPathLocal -TargetPath ([string]$itemOutput) } else { $script:ResolvedOutputRoot }
        $effectiveOutside = ($effectiveOutput.TrimEnd('\').ToLowerInvariant() -ne $script:DefaultOutputRoot.TrimEnd('\').ToLowerInvariant())
        $ctx = New-OutputPathContext -SourceRoot $sourceRoot -OutputRoot $effectiveOutput -UseOutsideOutputRoot $effectiveOutside
        # Keep the collision map at run scope while keeping source-root and
        # output policy item-scoped. This prevents two input roots from
        # overwriting the same explicit OutputRoot leaf under -Force.
        $ctx.seen_map = $runSeenMap
        $itemMode = [string](Get-ManifestItemSetting -Item $item -Defaults $manifest.defaults -Name 'mode')
        $itemSafety = [string](Get-ManifestItemSetting -Item $item -Defaults $manifest.defaults -Name 'safety_mode')
        $itemTarget = Get-ManifestItemSetting -Item $item -Defaults $manifest.defaults -Name 'target_bytes'
        $itemOcr = Get-ManifestItemSetting -Item $item -Defaults $manifest.defaults -Name 'ocr'
        $itemOcrEnabled = [bool](Get-ManifestPropertyValue -Object $itemOcr -Name 'enabled' $false)
        $itemOcrLanguages = @((Get-ManifestPropertyValue -Object $itemOcr -Name 'languages' @()))
        # Legacy single-item call shape: Invoke-CompressOne -Pdf $f -Tools $tools -Strategies $script:Strategies
        $f = $file
        $res = Invoke-CompressOne -Pdf $f -Tools $tools -Strategies $script:Strategies -Item $item -OutputContext $ctx -Capabilities $tools.capabilities -ItemMode $itemMode -ItemSafetyMode $itemSafety -ItemTargetBytes $itemTarget -ItemEnableOcr $itemOcrEnabled -ItemOcrLanguages $itemOcrLanguages -ItemAllowSignedPdf:([bool]$item.allow_signed_pdf) -ItemAllowFullPageRaster:([bool]$item.allow_full_page_raster) -ItemAllowReducedVerification:$AllowReducedVerification -ItemForce:$Force -ItemPreflightOnly:$PreflightOnly
        $runSeenMap = $ctx.seen_map
        if ($PreflightOnly) {
            if ($StatusJson) {
                $analysis = Get-ResultProperty $res 'analysis' ([ordered]@{})
                Write-StatusJsonLine -Payload ([ordered]@{ event='analysis'; file=$file.FullName; item_id=$res.item_id; reason=if ($analysis.policy_reason) { [string]$analysis.policy_reason } else { 'preflight' }; status=$analysis.status; page_count=$analysis.page_count; image_ratio=$analysis.image_ratio; avg_dpi=$analysis.avg_dpi; has_images=$analysis.has_images; selection_reason=$analysis.selection_reason; strategy_id=$analysis.strategy_id; verification_status=$analysis.verification_status; verification_reasons=@($analysis.verification_reasons); safety_action=$analysis.safety_action; policy_reason=$analysis.policy_reason; features=$analysis.features; warnings=@($analysis.warnings) })
            }
            continue
        }
        if ($StatusJson) { Write-StatusJsonLine -Payload ([ordered]@{ event='verification'; file=$file.FullName; item_id=$res.item_id; status=$res.verification_status; reasons=@($res.verification_reasons) }) }
        Write-ResultLine -Res $res -Jsonl $LogPath -Index $idx
        switch ($res.status) {
            'ok' { $okN++ }
            'skip' { $skipN++; if ($res.fail_reason -eq 'exists') { $existsN++ } }
            'fail' { $failN++ }
        }
        if ($res.stop_reason) {
            $actionN++
            $reasonKey = [string]$res.stop_reason
            if (-not $stopReasons.ContainsKey($reasonKey)) { $stopReasons[$reasonKey] = 0 }
            $stopReasons[$reasonKey]++
        }
    }
    if ($PreflightOnly) {
        if ($StatusJson) { Write-StatusJsonLine -Payload ([ordered]@{ event='summary'; total=$manifest.items.Count; analyzed=$manifest.items.Count; preflight_only=$true }) }
        return 0
    }
    $total=$okN+$skipN+$failN; $skipPct=if($total -gt 0){[int][math]::Round($skipN*100.0/$total)}else{0}
    Write-Host ("[SUMMARY] total={0} ok={1} skip={2} fail={3} skip_ratio={4}%" -f $total,$okN,$skipN,$failN,$skipPct)
    if ($existsN -gt 0 -and -not $Force) { Write-Host ("[INFO] {0} file(s) skipped because output already exists. Re-run with --Force to overwrite." -f $existsN) -ForegroundColor Yellow }
    $stopReasonPayload = @($stopReasons.GetEnumerator() | Sort-Object Name | ForEach-Object { [ordered]@{ reason = [string]$_.Name; count = [int]$_.Value } })
    if ($StatusJson) { Write-StatusJsonLine -Payload ([ordered]@{ event='summary'; total=$total; ok=$okN; skip=$skipN; fail=$failN; exists=$existsN; action_required=$actionN; stop_reasons=$stopReasonPayload; skip_ratio=$skipPct }) }
    # Exit priority: failN>0 -> 1, then existsN>0 && !Force -> 4, then action -> 6, then 0.
    if ($failN -gt 0) { return 1 }
    if (-not $Force -and $existsN -gt 0) { return 4 }
    if ($actionN -gt 0) { return 6 }
    return 0
} catch [PathGuardException] {
    $message = $_.Exception.Message
    Write-Host "[ERROR] $message" -ForegroundColor Red
    if ($message -like 'input-guard:*' -or $message -like '*input path*' -or $message -like '*not a PDF*') { return 3 }
    return 5
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    return 1
}
}

if ($env:PDFCOMP_SKIP_MAIN) { return }
exit (Invoke-PdfCompressorMain @PSBoundParameters)
