# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Shared human/status/log formatting helpers.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1073741824) { return ([math]::Round($Bytes / 1073741824.0, 1)).ToString('F1', $inv) + ' GB' }
    if ($Bytes -ge 1048576) { return ([math]::Round($Bytes / 1048576.0, 1)).ToString('F1', $inv) + ' MB' }
    if ($Bytes -ge 1024) { return ([math]::Round($Bytes / 1024.0, 1)).ToString('F1', $inv) + ' KB' }
    return $Bytes.ToString('F0', $inv) + ' B'
}

function ConvertTo-JsonlResultRecord {
    param([Parameter(Mandatory)][object]$Result)
    $record = [ordered]@{}
    foreach ($name in @('ts','item_id','file','status','strategy_id','tool','original','compressed','ratio_pct','fail_reason',
                        'mode','safety_mode','features','selection_reason','verification_status','verification_reasons',
                        'target_bytes','target_status','target_met','attempt_count','stop_reason','ocr_status','policy_reason','output_path','warnings')) {
        if ($Result.PSObject.Properties[$name]) { $record[$name] = $Result.$name }
    }
    if (-not $record.Contains('ts')) { $record['ts'] = (Get-Date).ToUniversalTime().ToString('o') }
    return $record
}

function ConvertTo-StatusEvent {
    param(
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][object]$Payload
    )
    $eventPayload = [ordered]@{ event = $Event }
    foreach ($property in $Payload.PSObject.Properties) { $eventPayload[$property.Name] = $property.Value }
    return $eventPayload
}
