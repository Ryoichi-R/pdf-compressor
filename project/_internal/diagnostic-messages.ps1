# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Shared diagnostic-message lookup for CLI diagnostics and the GUI.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DiagnosticMessage {
    param(
        [Parameter(Mandatory)][string]$Code,
        [hashtable]$Values = @{},
        [object]$Data,
        [string]$Path = (Join-Path $PSScriptRoot 'data\diagnostic-messages.json')
    )
    $fallback = $Code
    try {
        $source = if ($Data) {
            $Data
        } elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
            Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        } else {
            return $fallback
        }
        $message = if ($source.messages.PSObject.Properties[$Code]) { [string]$source.messages.$Code } else { $fallback }
        foreach ($key in $Values.Keys) { $message = $message.Replace('{' + $key + '}', [string]$Values[$key]) }
        return $message
    } catch { return $fallback }
}
