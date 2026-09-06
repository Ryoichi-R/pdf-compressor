[CmdletBinding()]
param([string]$ReceiptPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..')).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $ReceiptPath = Join-Path $projectRoot "_work\performance-gui-queue-scale-$stamp.json"
}
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if (-not $ReceiptPath.StartsWith($repositoryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReceiptPath must be inside the repository root.'
}

. (Join-Path $projectRoot '_internal\gui-queue.ps1')
$process = [Diagnostics.Process]::GetCurrentProcess()
$results = @()
foreach ($count in @(1, 10, 100, 1000)) {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect()
    $process.Refresh()
    $beforeWorkingSet = [long]$process.WorkingSet64
    $beforePrivateBytes = [long]$process.PrivateMemorySize64
    $beforeHandles = [int]$process.HandleCount
    $queue = New-GuiQueueState
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($index = 1; $index -le $count; $index++) {
        $item = New-GuiQueueItem -InputPath (Join-Path $projectRoot ("benchmark\queue-{0:D4}.pdf" -f $index))
        Add-GuiQueueItem -Queue $queue -Item $item | Out-Null
        Set-GuiQueueItemState -Item $item -State ready | Out-Null
    }
    $progress = Get-GuiQueueProgress -Queue $queue
    $availability = Test-RunAvailability -Queue $queue
    $logBytes = [Text.Encoding]::UTF8.GetByteCount((@($queue.items | ForEach-Object {
                    [ordered]@{ event = 'queue'; item_id = $_.item_id; input_path = $_.input_path; state = $_.state } | ConvertTo-Json -Compress
                }) -join "`n") + "`n")
    $watch.Stop()
    $process.Refresh()
    $results += [pscustomobject][ordered]@{
        queueCount = $count
        status = if ($progress.total -eq $count -and $progress.pending -eq 0 -and $availability.enabled) { 'pass' } else { 'fail' }
        wallMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 3)
        workingSetDeltaBytes = [long]$process.WorkingSet64 - $beforeWorkingSet
        privateBytesDelta = [long]$process.PrivateMemorySize64 - $beforePrivateBytes
        handleDelta = [int]$process.HandleCount - $beforeHandles
        serializedJsonlBytes = $logBytes
        runEnabled = [bool]$availability.enabled
    }
    $queue = $null
}

$receipt = [ordered]@{
    schemaVersion = 1
    measuredAtUtc = [DateTime]::UtcNow.ToString('o')
    status = if (@($results | Where-Object status -ne 'pass').Count -eq 0) { 'pass' } else { 'fail' }
    benchmark = 'gui-queue-pure-logic-scale'
    results = @($results)
    environment = [ordered]@{ os = [Environment]::OSVersion.VersionString; processorCount = [Environment]::ProcessorCount; powershell = $PSVersionTable.PSVersion.ToString() }
    limitations = @(
        'This measures queue model construction, state transition, progress, Run-gate, and representative JSONL growth.',
        'WinForms repaint latency and interactive responsiveness remain a manual installed-GUI measurement.',
        'Working-set and private-byte deltas are process-level samples and may include runtime allocation noise.'
    )
}
$directory = Split-Path -Parent $ReceiptPath
if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
[IO.File]::WriteAllText($ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ receiptPath = $ReceiptPath; status = $receipt.status; scales = $results.Count }
