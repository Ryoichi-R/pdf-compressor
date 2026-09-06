# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Pure queue and Run-gate contracts shared by GUI tests and the WinForms UI.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:QueueStates = @('pending','analyzing','ready','running','ok','skip','fail','cancelled')
$script:AllowedQueueTransitions = @{
    pending = @('analyzing','ready','skip','fail','cancelled')
    analyzing = @('ready','skip','fail','cancelled')
    ready = @('running','cancelled')
    running = @('ok','skip','fail','cancelled')
    ok = @(); skip = @(); fail = @(); cancelled = @('ready')
}

function New-GuiQueueState {
    return [pscustomobject]@{ version = '1.0'; items = [System.Collections.Generic.List[object]]::new() }
}

function New-GuiQueueItem {
    param([Parameter(Mandatory)][string]$InputPath,[string]$Mode = 'auto',[string]$SafetyMode = 'Safe',[Nullable[long]]$TargetBytes)
    return [pscustomobject]@{
        item_id = [Guid]::NewGuid().ToString('N'); input_path = [System.IO.Path]::GetFullPath($InputPath); state = 'pending'
        mode = $Mode; safety_mode = $SafetyMode; target_bytes = if ($null -ne $TargetBytes) { [long]$TargetBytes } else { $null }
        strategy_id = $null; analysis = $null; result = $null; policy_reason = $null
    }
}

function Add-GuiQueueItem {
    param([Parameter(Mandatory)][object]$Queue,[Parameter(Mandatory)][object]$Item)
    $key = $Item.input_path.ToLowerInvariant()
    foreach ($existing in $Queue.items) { if ($existing.input_path.ToLowerInvariant() -eq $key) { return $existing } }
    $Queue.items.Add($Item)
    return $Item
}

function Remove-GuiQueueItems {
    param(
        [Parameter(Mandatory)][object]$Queue,
        [Parameter(Mandatory)][string[]]$ItemIds
    )
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($itemId in $ItemIds) {
        if (-not [string]::IsNullOrWhiteSpace($itemId)) { [void]$ids.Add($itemId) }
    }
    $removed = [System.Collections.Generic.List[object]]::new()
    for ($index = $Queue.items.Count - 1; $index -ge 0; $index--) {
        $item = $Queue.items[$index]
        if ($ids.Contains([string]$item.item_id)) {
            $removed.Insert(0, $item)
            $Queue.items.RemoveAt($index)
        }
    }
    return [pscustomobject]@{ removed_count = $removed.Count; items = @($removed) }
}

function Set-GuiQueueItemState {
    param([Parameter(Mandatory)][object]$Item,[Parameter(Mandatory)][string]$State)
    if ($State -notin $script:QueueStates) { throw "gui-queue: unknown state '$State'." }
    $allowed = @($script:AllowedQueueTransitions[[string]$Item.state])
    if ($State -ne $Item.state -and $allowed -notcontains $State) { throw "gui-queue: invalid transition '$($Item.state)' -> '$State'." }
    $Item.state = $State
    return $Item
}

function Complete-GuiQueueCancellation {
    param(
        [Parameter(Mandatory)][object]$Queue,
        [string]$InFlightPath
    )
    $runningItems = @($Queue.items | Where-Object { $_.state -eq 'running' })
    $resolvedPath = if (-not [string]::IsNullOrWhiteSpace($InFlightPath)) {
        [System.IO.Path]::GetFullPath($InFlightPath)
    } elseif ($runningItems.Count -gt 0) {
        [string]$runningItems[0].input_path
    } else {
        $null
    }
    foreach ($item in $runningItems) {
        [void](Set-GuiQueueItemState -Item $item -State 'cancelled')
    }
    $cancelledCount = @($Queue.items | Where-Object { $_.state -eq 'cancelled' }).Count
    return [pscustomobject]@{
        in_flight_path = $resolvedPath
        cancelled_count = $cancelledCount
        items = @($runningItems)
    }
}

function Get-GuiQueueProgress {
    param([Parameter(Mandatory)][object]$Queue)
    $total = @($Queue.items).Count
    $done = @($Queue.items | Where-Object { $_.state -in @('ok','skip','fail','cancelled') }).Count
    return [pscustomobject]@{ done = $done; total = $total; pending = @($Queue.items | Where-Object state -eq 'pending').Count; running = @($Queue.items | Where-Object state -eq 'running').Count }
}

function Test-RunAvailability {
    [CmdletBinding()]
    param(
        [object]$Queue,
        [bool]$OutputValid = $true,
        [bool]$RequiredCapabilitiesAvailable = $true,
        [bool]$SafetyConfirmationPending = $false,
        [bool]$ChildProcessRunning = $false
    )
    $ready = if ($Queue) { @($Queue.items | Where-Object { $_.state -in @('ready','cancelled') }).Count -gt 0 } else { $false }
    $reasons = @()
    if (-not $ready) { $reasons += 'no-ready-item' }
    if (-not $OutputValid) { $reasons += 'invalid-output' }
    if (-not $RequiredCapabilitiesAvailable) { $reasons += 'required-capability-unavailable' }
    if ($SafetyConfirmationPending) { $reasons += 'safety-confirmation-pending' }
    if ($ChildProcessRunning) { $reasons += 'child-process-running' }
    return [pscustomobject]@{ enabled = ($ready -and $OutputValid -and $RequiredCapabilitiesAvailable -and -not $SafetyConfirmationPending -and -not $ChildProcessRunning); reasons = @($reasons) }
}

function Update-RunAvailability {
    param([Parameter(Mandatory)][object]$Queue,[Parameter(Mandatory)][object]$Button,[bool]$OutputValid = $true,[bool]$RequiredCapabilitiesAvailable = $true,[bool]$SafetyConfirmationPending = $false,[bool]$ChildProcessRunning = $false)
    $availability = Test-RunAvailability -Queue $Queue -OutputValid $OutputValid -RequiredCapabilitiesAvailable $RequiredCapabilitiesAvailable -SafetyConfirmationPending $SafetyConfirmationPending -ChildProcessRunning $ChildProcessRunning
    $Button.Enabled = $availability.enabled
    if ($Button.PSObject.Properties['ToolTipText']) { $Button.ToolTipText = ($availability.reasons -join ', ') }
    return $availability
}
