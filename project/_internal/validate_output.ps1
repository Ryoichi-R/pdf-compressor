# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Validate candidate PDFs before they leave _work.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-QpdfWarning {
    param([Parameter(Mandatory)][string]$Line)
    $text = $Line -replace '(?i)([A-Za-z]:\\|/)[^\s]+','<path>'
    $text = $text -replace '(?i)offset\s+\d+','offset N'
    $text = $text -replace '(?i)object\s+\d+\s+\d+','object N M'
    $text = $text -replace '(?i)0x[0-9a-f]+','0xADDR'
    $category = if ($text -match '(?i)damaged|recover|xref') { 'damaged-xref' }
               elseif ($text -match '(?i)syntax|parse') { 'syntax' }
               elseif ($text -match '(?i)stream') { 'stream' }
               elseif ($text -match '(?i)encrypt|password') { 'encryption' }
               elseif ($text -match '(?i)linear') { 'linearization' }
               else { 'unclassified-warning' }
    return [pscustomobject]@{ category = $category; severity = if ($category -eq 'unclassified-warning') { 'unknown' } else { 'warning' }; text = $text }
}

function Invoke-QpdfCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$QpdfExe,[Parameter(Mandatory)][string]$PdfPath)
    if (-not (Test-Path -LiteralPath $QpdfExe -PathType Leaf)) {
        return [pscustomobject]@{ status = 'unavailable'; exit_code = $null; warnings = @(); raw = 'qpdf-not-found' }
    }
    try {
        $out = @(& $QpdfExe '--check' '--' $PdfPath 2>&1)
        $rc = [int]$LASTEXITCODE
        $lines = @($out | ForEach-Object { [string]$_ } | Where-Object { $_ -match '(?i)warning|error|damaged|syntax|stream|xref|linear' })
        $warnings = @($lines | ForEach-Object { Normalize-QpdfWarning -Line $_ })
        $status = switch ($rc) { 0 { 'clean' } 3 { 'warning' } 2 { 'error' } default { 'tool-failure' } }
        return [pscustomobject]@{ status = $status; exit_code = $rc; warnings = @($warnings); raw = (($out -join "`n").Substring(0,[math]::Min(4096,(($out -join "`n").Length)))) }
    } catch { return [pscustomobject]@{ status = 'tool-failure'; exit_code = $null; warnings = @([pscustomobject]@{ category = 'unclassified-warning'; severity = 'unknown'; text = $_.Exception.Message }); raw = $_.Exception.Message } }
}

function Get-FeatureStateFromResult {
    param([object]$FeatureResult,[string]$Name)
    if ($null -eq $FeatureResult) { return 'unavailable' }
    if ($FeatureResult.features) {
        $container = $FeatureResult.features
        if ($container -is [System.Collections.IDictionary] -and $container.Contains($Name)) {
            $entry = $container[$Name]
            if ($entry -and $entry.PSObject.Properties['state']) { return [string]$entry.state }
        }
        if ($container.PSObject.Properties[$Name]) {
            $entry = $container.$Name
            if ($entry -and $entry.PSObject.Properties['state']) { return [string]$entry.state }
        }
    }
    return 'unavailable'
}

function Get-ValidationFeaturePolicyAction {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][ValidateSet('Safe','Warn','Off')][string]$SafetyMode)
    $policy = if (Get-Command Get-SafetyPolicyDefinition -ErrorAction SilentlyContinue) {
        Get-SafetyPolicyDefinition
    } else {
        $path = Join-Path $PSScriptRoot 'data\safety-policy.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'record' }
        Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if ($policy.features.PSObject.Properties[$Name] -and $policy.features.$Name.PSObject.Properties[$SafetyMode]) {
        return [string]$policy.features.$Name.$SafetyMode
    }
    return 'record'
}

function Validate-CompressedPdf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPdf,
        [Parameter(Mandatory)][string]$CandidatePdf,
        [Parameter(Mandatory)][string]$QpdfExe,
        [Parameter(Mandatory)][string]$PdfInfoExe,
        [object]$BeforeStructure,
        [object]$AfterStructure,
        [object]$BeforeFeatures,
        [object]$AfterFeatures,
        [ValidateSet('Safe','Warn','Off')][string]$SafetyMode = 'Safe',
        [ValidateRange(0.01, 1.0)][decimal]$StructureBoxTolerance = 0.01
    )
    $inputCheck = Invoke-QpdfCheck -QpdfExe $QpdfExe -PdfPath $InputPdf
    $outputCheck = Invoke-QpdfCheck -QpdfExe $QpdfExe -PdfPath $CandidatePdf
    $reasons = @()
    $status = 'verified'
    if ($inputCheck.status -eq 'unavailable') { $status = 'unavailable'; $reasons += 'qpdf-input-unavailable' }
    elseif ($inputCheck.status -in @('error','tool-failure')) { $status = 'rejected'; $reasons += "qpdf-input-$($inputCheck.status)" }
    if ($outputCheck.status -eq 'unavailable') { $status = 'unavailable'; $reasons += 'qpdf-unavailable' }
    elseif ($outputCheck.status -in @('error','tool-failure')) { $status = 'rejected'; $reasons += "qpdf-output-$($outputCheck.status)" }
    elseif ($outputCheck.status -eq 'warning') {
        $inputCategories = @($inputCheck.warnings | ForEach-Object { $_.category })
        $newWarnings = @($outputCheck.warnings | Where-Object { $inputCategories -notcontains $_.category })
        $unknownWarnings = @($outputCheck.warnings | Where-Object { $_.severity -eq 'unknown' })
        if ($unknownWarnings.Count -gt 0) {
            $reasons += 'unclassified-qpdf-warning'
            if ($SafetyMode -eq 'Safe') { $status = 'rejected' }
            elseif ($status -eq 'verified') { $status = 'warning' }
        }
        if ($newWarnings.Count -gt 0) {
            if ($SafetyMode -eq 'Safe') { $status = 'rejected' }
            elseif ($status -eq 'verified') { $status = 'warning' }
            $reasons += @($newWarnings | ForEach-Object { "new-qpdf-warning:$($_.category)" })
        }
    }
    $structure = $null
    if ($BeforeStructure -and $AfterStructure) {
        $structure = Compare-PdfStructureSnapshot -Before $BeforeStructure -After $AfterStructure -Tolerance $StructureBoxTolerance
        if (-not $structure.equal) { $status = 'rejected'; $reasons += @($structure.reasons) }
        if ($BeforeStructure.status -eq 'indeterminate' -or $AfterStructure.status -eq 'indeterminate') {
            if ($SafetyMode -eq 'Safe') { $status = 'rejected' }
            elseif ($status -eq 'verified') { $status = 'indeterminate' }
            $reasons += 'structure-indeterminate'
        }
    }
    $losses = @()
    if ($BeforeFeatures -and $AfterFeatures) {
        foreach ($name in @('pdfa','pdfx','acroform','xfa','annotations','outlines','links','attachments','javascript','tagged','layers')) {
            $before = Get-FeatureStateFromResult $BeforeFeatures $name
            $after = Get-FeatureStateFromResult $AfterFeatures $name
            if ($before -eq 'present' -and $after -eq 'absent') {
                $directive = Get-ValidationFeaturePolicyAction -Name $name -SafetyMode $SafetyMode
                switch ($directive) {
                    'preserve' { $losses += $name; $reasons += "feature-loss:$name" }
                    'warn' { $reasons += "feature-loss-warning:$name"; if ($status -eq 'verified') { $status = 'warning' } }
                    'confirm' { $reasons += "feature-loss-confirmation:$name"; if ($SafetyMode -eq 'Safe') { $status = 'rejected' } elseif ($status -eq 'verified') { $status = 'warning' } }
                    default { $reasons += "feature-loss-recorded:$name" }
                }
            }
        }
        if ($losses.Count -gt 0 -and $SafetyMode -eq 'Safe') { $status = 'rejected' }
        if ((Get-FeatureStateFromResult $BeforeFeatures 'digital_signature') -eq 'present') {
            $reasons += 'signature-preservation-not-claimed'
            if ($status -eq 'verified') { $status = 'warning' }
        }
    }
    return [pscustomobject]@{
        status = $status
        verification_status = $status
        accepted = ($status -in @('verified','warning'))
        qpdf_check = [pscustomobject]@{ input_exit = $inputCheck.exit_code; output_exit = $outputCheck.exit_code; input_status = $inputCheck.status; output_status = $outputCheck.status; new_warnings = @($reasons | Where-Object { $_ -like 'new-qpdf-warning:*' }) }
        structure = $structure
        features = [pscustomobject]@{ losses = @($losses) }
        reasons = @($reasons)
    }
}
