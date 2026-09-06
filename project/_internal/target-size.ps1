# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Bounded target-size candidate policy and result selection.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModeIds = @('auto','high-quality','standard','minimum-size')

function Get-ModeDefinitions {
    param([string]$Path = (Join-Path $PSScriptRoot 'data\modes.json'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "target-size: modes file not found '$Path'." }
    $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return $obj.modes
}

function Get-ModeDefinition {
    param([Parameter(Mandatory)][string]$Mode,[object]$Definitions)
    if ($Mode -notin $script:ModeIds) { throw "target-size: invalid mode '$Mode'." }
    $defs = if ($Definitions) { @($Definitions) } else { @(Get-ModeDefinitions) }
    foreach ($definition in $defs) { if ([string]$definition.mode_id -eq $Mode) { return $definition } }
    throw "target-size: mode '$Mode' is not defined."
}

function Get-StrategyCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][object]$Metrics,
        [Parameter(Mandatory)][object]$Strategies,
        [object]$Capabilities,
        [switch]$AllowFullPageRaster,
        [string]$StrategyOverride
    )
    $definition = Get-ModeDefinition -Mode $Mode
    $ids = @()
    if ($StrategyOverride -and $StrategyOverride -ne 'auto') { $ids = @($StrategyOverride) }
    else {
        $auto = Select-CompressionStrategy -Metrics $Metrics -Strategies $Strategies
        $ids = @($definition.strategies)
        if ($Mode -eq 'auto') { $ids = @($auto.strategy_id); if ($auto.fallback) { $ids += [string]$auto.fallback } }
    }
    $seen = @{}
    $rank = 0
    $out = foreach ($id in $ids) {
        if ($seen.ContainsKey([string]$id)) { continue }
        $seen[[string]$id] = $true
        if ([string]$id -in @('gs-raster-low-quality','gs-raster-readable') -and -not $AllowFullPageRaster) { continue }
        if ($Capabilities) {
            $cap = Test-StrategyCapability -Capabilities $Capabilities -StrategyId ([string]$id)
            if (-not $cap.available) { continue }
        }
        $strategy = Get-StrategyById -Config $Strategies -Id ([string]$id)
        $rank++
        [pscustomobject]@{ strategy_id = [string]$id; quality_rank = $rank; definition = $strategy }
    }
    return @($out)
}

function Test-TargetBytes {
    param([Nullable[long]]$TargetBytes)
    return ($null -ne $TargetBytes -and [long]$TargetBytes -gt 0)
}

function Select-BestTargetCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][long]$TargetBytes,
        [long]$OriginalBytes = 0L,
        [int]$MaxAttempts = 7,
        [string]$StopReason = $null
    )
    $bounded = @($Candidates | Select-Object -First ([math]::Max(1,$MaxAttempts)))
    $valid = @($bounded | Where-Object { $_.valid -eq $true -and $_.bytes -gt 0 -and ($OriginalBytes -le 0 -or $_.bytes -lt $OriginalBytes) })
    if ($valid.Count -eq 0) {
        return [pscustomobject]@{ selected = $null; target_status = 'no-valid-candidate'; target_met = $false; best_valid_bytes = $null; attempt_count = $bounded.Count; stop_reason = if ($StopReason) { $StopReason } else { 'no-valid-candidate' } }
    }
    $met = @($valid | Where-Object { [long]$_.bytes -le $TargetBytes } | Sort-Object quality_rank | Select-Object -First 1)
    if ($met.Count -gt 0) {
        return [pscustomobject]@{ selected = $met[0]; target_status = 'met'; target_met = $true; best_valid_bytes = [long]$met[0].bytes; attempt_count = $bounded.Count; stop_reason = $StopReason }
    }
    $smallest = $valid | Sort-Object bytes | Select-Object -First 1
    return [pscustomobject]@{ selected = $smallest; target_status = 'not-met'; target_met = $false; best_valid_bytes = [long]$smallest.bytes; attempt_count = $bounded.Count; stop_reason = if ($StopReason) { $StopReason } else { 'target-not-met' } }
}
