# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Shared Safe/Warn/Off policy decisions.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SafetyPolicyPath = Join-Path $PSScriptRoot 'data\safety-policy.json'

function Get-SafetyPolicyDefinition {
    if (-not (Test-Path -LiteralPath $script:SafetyPolicyPath -PathType Leaf)) {
        throw "safety-policy: policy file not found '$script:SafetyPolicyPath'."
    }
    return Get-Content -LiteralPath $script:SafetyPolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-PdfFeatureStateValue {
    param([object]$Features,[string]$Name)
    if ($null -eq $Features) { return 'unavailable' }
    if ($Features.PSObject.Properties['features'] -and $Features.features) {
        $container = $Features.features
        if ($container -is [System.Collections.IDictionary] -and $container.Contains($Name)) {
            $entry = $container[$Name]
            if ($entry -and $entry.PSObject.Properties['state']) { return [string]$entry.state }
        }
        if ($container.PSObject.Properties[$Name]) {
            $entry = $container.$Name
            if ($entry -and $entry.PSObject.Properties['state']) { return [string]$entry.state }
        }
    }
    if ($Features.PSObject.Properties[$Name]) {
        $entry = $Features.$Name
        if ($entry.PSObject.Properties['state']) { return [string]$entry.state }
        return [string]$entry
    }
    return 'unavailable'
}

function Get-SafetyPolicyAction {
    param([Parameter(Mandatory)][object]$Policy,[Parameter(Mandatory)][string]$FeatureName,[Parameter(Mandatory)][ValidateSet('Safe','Warn','Off')][string]$SafetyMode)
    if ($null -eq $Policy.features -or -not $Policy.features.PSObject.Properties[$FeatureName]) { return 'record' }
    $definition = $Policy.features.$FeatureName
    if ($definition.PSObject.Properties[$SafetyMode]) { return [string]$definition.$SafetyMode }
    return 'record'
}

function Get-SafetyDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Features,
        [ValidateSet('Safe','Warn','Off')][string]$SafetyMode = 'Safe',
        [Parameter(Mandatory)][string]$StrategyId,
        [switch]$AllowSignedPdf,
        [switch]$AllowFullPageRaster,
        [switch]$AllowReducedVerification
    )
    $warnings = @()
    $reasons = @()
    $action = 'continue'
    $verification = 'verified'
    $policy = Get-SafetyPolicyDefinition
    $rasterStrategyIds = @($policy.raster_strategy_ids)
    $regenerationStrategyIds = @($policy.regeneration_strategy_ids)
    $requiredDetectionFeatures = @($policy.required_detection_features)
    $signature = Get-PdfFeatureStateValue -Features $Features -Name 'digital_signature'
    $encrypted = Get-PdfFeatureStateValue -Features $Features -Name 'encrypted'
    $policyFeatureNames = @($policy.features.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $indeterminate = @()
    $preserveFeatures = @()
    $presentFeatures = @()

    if ($encrypted -eq 'present') {
        $action = 'skip'; $reasons += 'encrypted'; $verification = 'rejected'
    }
    if ($signature -eq 'present') {
        $presentFeatures += 'digital_signature'
        if (-not $AllowSignedPdf) {
            $action = 'skip'; $reasons += 'signed-pdf'; $verification = 'rejected'
        } else {
            $warnings += 'signed-pdf-explicitly-allowed-signature-not-preserved'; $reasons += 'signed-pdf-allowed'; $verification = 'warning'
        }
    }

    foreach ($name in $policyFeatureNames | Where-Object { $_ -notin @('digital_signature','encrypted') }) {
        $state = Get-PdfFeatureStateValue -Features $Features -Name $name
        $directive = Get-SafetyPolicyAction -Policy $policy -FeatureName $name -SafetyMode $SafetyMode
        if ($state -eq 'present') {
            $presentFeatures += $name
            switch ($directive) {
                'skip' {
                    $action = 'skip'; $verification = 'rejected'; $reasons += "feature-policy-skip:$name"
                }
                'confirm' {
                    if ($SafetyMode -eq 'Safe') {
                        $action = 'skip'; $verification = 'rejected'; $reasons += "feature-policy-confirm:$name"
                    } elseif (-not $AllowReducedVerification) {
                        $action = 'confirm'; $verification = 'indeterminate'; $reasons += "feature-policy-confirm:$name"; $warnings += "feature-confirmation-required:$name"
                    } else {
                        $verification = 'warning'; $warnings += "feature-confirmation-accepted:$name"
                    }
                }
                'warn' { $warnings += "feature-present:$name" }
                'preserve' { $preserveFeatures += $name }
                default { }
            }
        } elseif ($state -eq 'indeterminate' -and $name -notin $requiredDetectionFeatures -and $directive -ne 'record') {
            $indeterminate += $name
        }
    }

    if ($StrategyId -in $regenerationStrategyIds) {
        foreach ($name in @('pdfa','pdfx')) {
            if ((Get-PdfFeatureStateValue -Features $Features -Name $name) -eq 'present') {
                $preserveFeatures += $name
                $warnings += "standards-regeneration-warning:$name"
                $reasons += "standards-preservation-required:$name"
                if ($verification -eq 'verified') { $verification = 'warning' }
            }
        }
    }

    if ($StrategyId -in $rasterStrategyIds -and -not $AllowFullPageRaster) {
        $action = 'skip'; $reasons += 'full-page-raster-consent-required'; $verification = 'rejected'
    }

    # A full-page raster destroys interactive/semantic structures even when
    # the operator has consented to rasterization. The per-feature Safe/Warn/
    # Off action in safety-policy.json determines whether that loss is blocked,
    # confirmed, or merely recorded.
    if ($StrategyId -in $rasterStrategyIds -and $AllowFullPageRaster) {
        foreach ($name in $presentFeatures | Where-Object { $_ -notin @('digital_signature','encrypted') } | Select-Object -Unique) {
            $directive = Get-SafetyPolicyAction -Policy $policy -FeatureName $name -SafetyMode $SafetyMode
            if ($directive -eq 'record') { continue }
            $reasons += "full-page-raster-feature:$name"
            if ($SafetyMode -eq 'Safe') {
                $action = 'skip'; $verification = 'rejected'
            } elseif ($SafetyMode -eq 'Warn' -and -not $AllowReducedVerification) {
                $action = 'confirm'; $verification = 'indeterminate'; $warnings += "full-page-raster-feature-confirmation-required:$name"
            } else {
                $verification = 'warning'; $warnings += "full-page-raster-feature-risk:$name"
            }
        }
    }

    if ($indeterminate.Count -gt 0) {
        $reasons += @($indeterminate | ForEach-Object { "feature-indeterminate:$_" })
        if ($SafetyMode -eq 'Safe') {
            $action = 'skip'; $verification = 'indeterminate'
        } elseif (-not $AllowReducedVerification) {
            $action = 'confirm'; $verification = 'indeterminate'; $warnings += 'reduced-verification-consent-required'
        } else {
            $verification = 'warning'; $warnings += 'reduced-verification-accepted'
        }
    }
    $unavailable = @()
    foreach ($name in $requiredDetectionFeatures) {
        if ((Get-PdfFeatureStateValue -Features $Features -Name $name) -eq 'unavailable') { $unavailable += $name }
    }
    if ($unavailable.Count -gt 0) {
        $reasons += @($unavailable | ForEach-Object { "feature-unavailable:$_" })
        if ($SafetyMode -eq 'Safe') { $action = 'unavailable'; $verification = 'unavailable' }
        elseif (-not $AllowReducedVerification) { $action = 'confirm'; $verification = 'unavailable'; $warnings += 'reduced-verification-consent-required' }
        else { $verification = 'warning'; $warnings += 'reduced-verification-accepted' }
    }
    return [pscustomobject]@{
        action = $action
        allowed = ($action -eq 'continue')
        safety_mode = $SafetyMode
        verification_status = $verification
        policy_reason = if ($reasons.Count -gt 0) { $reasons -join ';' } else { 'safe-to-process' }
        reasons = @($reasons)
        warnings = @($warnings)
        allow_signed_pdf = [bool]$AllowSignedPdf
        allow_full_page_raster = [bool]$AllowFullPageRaster
        preserve_features = @($preserveFeatures | Select-Object -Unique)
        policy_version = [string]$policy.version
        policy_source = 'data/safety-policy.json'
    }
}

function Test-SafetyPolicy {
    param(
        [Parameter(Mandatory)][object]$Features,
        [ValidateSet('Safe','Warn','Off')][string]$SafetyMode = 'Safe',
        [Parameter(Mandatory)][string]$StrategyId,
        [switch]$AllowSignedPdf,
        [switch]$AllowFullPageRaster,
        [switch]$AllowReducedVerification
    )
    return Get-SafetyDecision @PSBoundParameters
}
