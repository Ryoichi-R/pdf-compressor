# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Strategy selection from PDF metrics. Reads thresholds from
    data/strategies.json. Validates DPI whitelist before returning.

.OUTPUTS
    PSCustomObject: strategy_id, tool, params (hashtable), reason (string)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Strategies {
    param([Parameter(Mandatory)][string]$JsonPath)
    if (-not (Test-Path -LiteralPath $JsonPath)) {
        throw "strategies.json not found: $JsonPath"
    }
    $raw = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8
    $schemaPath = Join-Path (Split-Path -Parent $JsonPath) 'strategies.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        throw "select_strategy: schema file not found: $schemaPath"
    }
    if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
        throw "select_strategy: Test-Json is not available. PowerShell 7+ (pwsh) is required."
    }
    $valid = Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction Stop
    if (-not $valid) {
        throw "select_strategy: strategies.json does not match strategies.schema.json"
    }
    $obj = $raw | ConvertFrom-Json
    Assert-StrategyFallbacks -Config $obj | Out-Null
    return $obj
}

function Get-StrategyFallback {
    <#
    .SYNOPSIS
        Return the fallback strategy_id for $Strategy, or $null when none is
        declared. StrictMode-safe (uses PSObject.Properties.Match).
    #>
    param([Parameter(Mandatory)][object]$Strategy)
    if ($Strategy.PSObject.Properties.Match('fallback').Count -eq 0) { return $null }
    $fb = $Strategy.fallback
    if ([string]::IsNullOrEmpty($fb)) { return $null }
    return [string]$fb
}

function Assert-StrategyFallbacks {
    <#
    .SYNOPSIS
        Semantic validation that JSON Schema cannot express: every declared
        fallback must reference an existing strategy_id, and fallback chains
        must terminate (no cycles).
    .OUTPUTS
        $true on success; throws on validation failure.
    #>
    param([Parameter(Mandatory)][object]$Config)

    $known = @{}
    foreach ($s in $Config.strategies) { $known[[string]$s.strategy_id] = $s }

    foreach ($s in $Config.strategies) {
        $fb = Get-StrategyFallback -Strategy $s
        if (-not $fb) { continue }
        if (-not $known.ContainsKey($fb)) {
            throw "select_strategy: strategy '$($s.strategy_id)' declares fallback '$fb' which is not defined in strategies.json."
        }
        # Cycle detection: walk the chain bounded by total strategy count.
        $seen = @{ [string]$s.strategy_id = $true }
        $cur = $known[$fb]
        $maxDepth = $Config.strategies.Count
        for ($i = 0; $i -lt $maxDepth; $i++) {
            $curId = [string]$cur.strategy_id
            if ($seen.ContainsKey($curId)) {
                throw "select_strategy: fallback cycle detected starting at '$($s.strategy_id)' -> '$curId'."
            }
            $seen[$curId] = $true
            $next = Get-StrategyFallback -Strategy $cur
            if (-not $next) { break }
            if (-not $known.ContainsKey($next)) {
                throw "select_strategy: strategy '$curId' declares fallback '$next' which is not defined in strategies.json."
            }
            $cur = $known[$next]
        }
    }
    return $true
}

function Assert-DpiAllowed {
    param(
        [Parameter(Mandatory)][int]$Dpi,
        [Parameter(Mandatory)][int[]]$Allowed
    )
    if ($Dpi -lt 72 -or $Dpi -gt 600) {
        throw "select_strategy: DPI $Dpi outside 72..600 range."
    }
    if ($Allowed -notcontains $Dpi) {
        throw "select_strategy: DPI $Dpi not in whitelist [$($Allowed -join ',')]."
    }
}

function Get-StrategyById {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Id
    )
    foreach ($s in $Config.strategies) {
        if ($s.strategy_id -eq $Id) { return $s }
    }
    throw "select_strategy: strategy '$Id' not defined in strategies.json"
}

function Select-CompressionStrategy {
    <#
    .PARAMETER Metrics
        Output of Get-PdfMetrics.
    .PARAMETER ConfigPath
        Path to strategies.json. Used only when -Strategies is not supplied.
    .PARAMETER Strategies
        Pre-loaded strategies object (output of Get-Strategies). Pass this from
        callers that loop over files to avoid the N+1 schema-validation hit
        (P1-3). When both are supplied, -Strategies wins.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Metrics,
        [Parameter()][string]$ConfigPath,
        [Parameter()][object]$Strategies
    )

    if ($Strategies) {
        $cfg = $Strategies
    } elseif ($ConfigPath) {
        $cfg = Get-Strategies -JsonPath $ConfigPath
    } else {
        throw "select_strategy: either -Strategies or -ConfigPath is required."
    }
    $allowed = @($cfg.allowed_dpi | ForEach-Object { [int]$_ })
    $tLow  = [double]$cfg.thresholds.image_ratio_low
    $tHigh = [double]$cfg.thresholds.image_ratio_high
    $dpiHigh = [int]$cfg.thresholds.dpi_high

    $ratio = [double]$Metrics.imageRatio
    $hasImg = [bool]$Metrics.hasImages
    $avgDpi = $null
    if ($null -ne $Metrics.avgDpi) { $avgDpi = [double]$Metrics.avgDpi }

    $sid = $null
    $reason = $null

    if (-not $hasImg -or $ratio -lt $tLow) {
        $sid = 'qpdf-lossless'
        $reason = "hasImages=$hasImg ratio=$ratio < $tLow -> text/vector dominant"
    }
    elseif ($ratio -ge $tHigh) {
        if ($null -ne $avgDpi -and $avgDpi -ge $dpiHigh) {
            $sid = 'gs-downsample-150'
            $reason = "ratio=$ratio >= $tHigh, avgDpi=$avgDpi >= $dpiHigh -> high-DPI scan"
        } else {
            $sid = 'qpdf-lossless'
            $reason = "ratio=$ratio >= $tHigh, avgDpi=$avgDpi < $dpiHigh -> try lossless first (fallback to gs-light-regenerate if no effect)"
        }
    }
    else {
        $sid = 'gs-downsample-180'
        $reason = "ratio=$ratio in [$tLow,$tHigh) -> mixed content"
    }

    $s = Get-StrategyById -Config $cfg -Id $sid

    $params = @{}
    if ($s.PSObject.Properties.Match('params').Count -gt 0 -and $null -ne $s.params) {
        foreach ($p in $s.params.PSObject.Properties) {
            $params[$p.Name] = $p.Value
        }
    }

    if ($s.tool -eq 'ghostscript') {
        if ($params.ContainsKey('color_dpi')) {
            Assert-DpiAllowed -Dpi ([int]$params.color_dpi) -Allowed $allowed
        }
        if ($params.ContainsKey('gray_dpi')) {
            Assert-DpiAllowed -Dpi ([int]$params.gray_dpi) -Allowed $allowed
        }
    }

    # Fallback is declared on the strategy in strategies.json (SSoT).
    # The conditional gate (only fire fallback for qpdf-lossless when the
    # ratio is high enough to suggest gs-light-regenerate would help) stays
    # in this selector — it's selection logic, not data.
    $declaredFallback = Get-StrategyFallback -Strategy $s
    $useFallback = ($declaredFallback -and $sid -eq 'qpdf-lossless' -and $ratio -ge $tHigh)

    return [pscustomobject]@{
        strategy_id = $sid
        tool        = $s.tool
        params      = $params
        reason      = $reason
        fallback    = if ($useFallback) { $declaredFallback } else { $null }
    }
}

function Get-ModeStrategyPlan {
    <#
    .SYNOPSIS
        Convert a user-facing mode into an ordered policy candidate list.

    .DESCRIPTION
        Modes are policies, not aliases for one raw strategy.  The returned
        list is subsequently filtered by metrics, safety, and capabilities.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('auto','high-quality','standard','minimum-size')]
        [string]$Mode = 'auto',
        [Parameter(Mandatory)][object]$Metrics,
        [Parameter(Mandatory)][object]$Strategies,
        [object]$Capabilities,
        [switch]$AllowFullPageRaster,
        [string]$StrategyOverride = 'auto'
    )
    if (-not (Get-Command Get-StrategyCandidates -ErrorAction SilentlyContinue)) {
        throw 'select_strategy: Get-StrategyCandidates is unavailable; load target-size.ps1 before selecting a mode plan.'
    }
    $items = @(Get-StrategyCandidates -Mode $Mode -Metrics $Metrics -Strategies $Strategies -Capabilities $Capabilities -AllowFullPageRaster:$AllowFullPageRaster -StrategyOverride $StrategyOverride)
    return @($items | ForEach-Object {
        [pscustomobject]@{ strategy_id = [string]$_.strategy_id; definition = $_.definition; mode = $Mode; rank = [int]$_.quality_rank }
    })
}
