# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    GUI settings persistence for pdf-compressor.

.DESCRIPTION
    Loads and saves user settings as JSON in %APPDATA%\pdf-compressor\settings.json.
    Provides default-value merge, version compatibility handling, and atomic write.

.NOTES
    Tested by: tests/unit/gui-settings.Tests.ps1
#>

Set-StrictMode -Version Latest

$script:GuiSettingsVersion = '1.0'

function Get-DefaultGuiSettings {
    return [pscustomobject]@{
        version      = $script:GuiSettingsVersion
        lastInput    = ''
        outputRoot   = ''
        lastStrategy = 'auto'
        mode         = 'auto'
        safetyMode   = 'Safe'
        targetBytes  = $null
        ocr          = [pscustomobject]@{ enabled = $false; languages = @() }
        force        = $false
        windowSize   = [pscustomobject]@{ w = 900; h = 700 }
        windowPos    = [pscustomobject]@{ x = -1; y = -1 }
    }
}

function Get-GuiSettingsPath {
    param([string]$AppDataOverride)
    $base = if ($AppDataOverride) { $AppDataOverride } else { $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "gui-settings: APPDATA is not set."
    }
    $dir = Join-Path $base 'pdf-compressor'
    return (Join-Path $dir 'settings.json')
}

function Merge-GuiSettings {
    <#
    .SYNOPSIS
        Merge a loaded settings object onto defaults, validating each field.
    #>
    param([Parameter()][object]$Loaded)

    $defaults = Get-DefaultGuiSettings
    $merged = [pscustomobject]@{
        version      = $defaults.version
        lastInput    = $defaults.lastInput
        outputRoot   = $defaults.outputRoot
        lastStrategy = $defaults.lastStrategy
        mode         = $defaults.mode
        safetyMode   = $defaults.safetyMode
        targetBytes  = $defaults.targetBytes
        ocr          = [pscustomobject]@{ enabled = $defaults.ocr.enabled; languages = @($defaults.ocr.languages) }
        force        = $defaults.force
        windowSize   = [pscustomobject]@{ w = $defaults.windowSize.w; h = $defaults.windowSize.h }
        windowPos    = [pscustomobject]@{ x = $defaults.windowPos.x; y = $defaults.windowPos.y }
    }

    if ($null -eq $Loaded) { return $merged }

    $allowedStrategies = @('auto','qpdf-lossless','gs-downsample-120','gs-downsample-150','gs-downsample-180','gs-light-regenerate','gs-raster-low-quality','gs-raster-readable')
    $allowedModes = @('auto','high-quality','standard','minimum-size')
    $allowedSafetyModes = @('Safe','Warn','Off')

    foreach ($prop in @('lastInput','outputRoot','lastStrategy')) {
        if ($Loaded.PSObject.Properties[$prop] -and $null -ne $Loaded.$prop) {
            $merged.$prop = [string]$Loaded.$prop
        }
    }
    if ($Loaded.PSObject.Properties['force'] -and $null -ne $Loaded.force) {
        try { $merged.force = [bool]$Loaded.force } catch { $merged.force = $false }
    }
    if ($merged.lastStrategy -notin $allowedStrategies) {
        $merged.lastStrategy = 'auto'
    }
    if ($Loaded.PSObject.Properties['mode'] -and [string]$Loaded.mode -in $allowedModes) { $merged.mode = [string]$Loaded.mode }
    elseif ($merged.lastStrategy -in $allowedModes) { $merged.mode = $merged.lastStrategy; $merged.lastStrategy = 'auto' }
    if ($Loaded.PSObject.Properties['safetyMode'] -and [string]$Loaded.safetyMode -in $allowedSafetyModes) { $merged.safetyMode = [string]$Loaded.safetyMode }
    if ($Loaded.PSObject.Properties['targetBytes'] -and $null -ne $Loaded.targetBytes) {
        try { $target = [long]$Loaded.targetBytes; if ($target -gt 0) { $merged.targetBytes = $target } } catch {}
    }
    if ($Loaded.PSObject.Properties['ocr'] -and $null -ne $Loaded.ocr) {
        if ($Loaded.ocr.PSObject.Properties['enabled']) { $merged.ocr.enabled = [bool]$Loaded.ocr.enabled }
        if ($Loaded.ocr.PSObject.Properties['languages']) { $merged.ocr.languages = @($Loaded.ocr.languages | ForEach-Object { [string]$_ } | Select-Object -Unique) }
    }

    if ($Loaded.PSObject.Properties['windowSize'] -and $null -ne $Loaded.windowSize) {
        $ws = $Loaded.windowSize
        if ($ws.PSObject.Properties['w'] -and $null -ne $ws.w) {
            try { $w = [int]$ws.w; if ($w -ge 400 -and $w -le 4000) { $merged.windowSize.w = $w } } catch {}
        }
        if ($ws.PSObject.Properties['h'] -and $null -ne $ws.h) {
            try { $h = [int]$ws.h; if ($h -ge 300 -and $h -le 4000) { $merged.windowSize.h = $h } } catch {}
        }
    }
    if ($Loaded.PSObject.Properties['windowPos'] -and $null -ne $Loaded.windowPos) {
        $wp = $Loaded.windowPos
        if ($wp.PSObject.Properties['x'] -and $null -ne $wp.x) {
            try { $merged.windowPos.x = [int]$wp.x } catch {}
        }
        if ($wp.PSObject.Properties['y'] -and $null -ne $wp.y) {
            try { $merged.windowPos.y = [int]$wp.y } catch {}
        }
    }

    return $merged
}

function Get-GuiSettings {
    <#
    .SYNOPSIS
        Load settings from %APPDATA%\pdf-compressor\settings.json with default merge.
    .PARAMETER Path
        Override file path (for testing).
    .OUTPUTS
        PSCustomObject with all fields populated.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path) { $Path = Get-GuiSettingsPath }

    if (-not (Test-Path -LiteralPath $Path)) {
        return Get-DefaultGuiSettings
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return Get-DefaultGuiSettings
        }
        $loaded = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "gui-settings: failed to parse '$Path': $($_.Exception.Message). Reverting to defaults."
        return Get-DefaultGuiSettings
    }

    if ($loaded.PSObject.Properties['version'] -and $loaded.version -ne $script:GuiSettingsVersion) {
        Write-Warning "gui-settings: version mismatch (file='$($loaded.version)' expected='$($script:GuiSettingsVersion)'). Reverting to defaults."
        return Get-DefaultGuiSettings
    }

    return (Merge-GuiSettings -Loaded $loaded)
}

function Save-GuiSettings {
    <#
    .SYNOPSIS
        Atomic write of settings JSON. Creates parent directory if missing.
    .PARAMETER Settings
        PSCustomObject as returned by Get-GuiSettings or Get-DefaultGuiSettings.
    .PARAMETER Path
        Override file path (for testing).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Settings,
        [string]$Path
    )

    if (-not $Path) { $Path = Get-GuiSettingsPath }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Always stamp the current version on save.
    if ($Settings.PSObject.Properties['version']) {
        $Settings.version = $script:GuiSettingsVersion
    }

    $tmp = $Path + '.tmp'
    $json = $Settings | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
