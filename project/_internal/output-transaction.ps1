# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-OutputTransactionJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record
    )
    $parent = Split-Path -Parent $JournalPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Transaction journal parent is missing: $parent" }
    $temporary = $JournalPath + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        $json = ($Record | ConvertTo-Json -Depth 6) + "`n"
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Move-Item -LiteralPath $temporary -Destination $JournalPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-OutputTransactionPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputPath)
    $token = [Guid]::NewGuid().ToString('N')
    [pscustomobject]@{
        journal = $OutputPath + '.pdfcomp-transaction.json'
        backup = $OutputPath + '.bak.' + $token
    }
}

function Read-ValidatedOutputTransactionJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputPath)
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $journalPath = $outputFull + '.pdfcomp-transaction.json'
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { return $null }
    if (((Get-Item -LiteralPath $journalPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'recovery-needed: transaction journal is a reparse point'
    }
    try { $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json } catch {
        throw 'recovery-needed: invalid output transaction journal JSON'
    }
    if ($journal.schemaVersion -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$journal.outputPath) -or
        [string]::IsNullOrWhiteSpace([string]$journal.backupPath) -or
        [string]$journal.state -notin @('prepared','backup-created','committed')) {
        throw 'recovery-needed: invalid output transaction journal'
    }
    $recordedOutput = [IO.Path]::GetFullPath([string]$journal.outputPath)
    if (-not $recordedOutput.Equals($outputFull,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'recovery-needed: output transaction journal path mismatch'
    }
    $backupFull = [IO.Path]::GetFullPath([string]$journal.backupPath)
    $expectedParent = [IO.Path]::GetFullPath((Split-Path -Parent $outputFull)).TrimEnd('\')
    $backupParent = [IO.Path]::GetFullPath((Split-Path -Parent $backupFull)).TrimEnd('\')
    $expectedLeafPattern = '^' + [regex]::Escape((Split-Path -Leaf $outputFull) + '.bak.') + '[0-9a-fA-F]{32}$'
    if (-not $backupParent.Equals($expectedParent,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $backupFull) -notmatch $expectedLeafPattern) {
        throw 'recovery-needed: unsafe output transaction backup path'
    }
    foreach ($path in @($outputFull,$backupFull)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "recovery-needed: transaction path is a reparse point: $path"
            }
        }
    }
    [pscustomobject]@{
        journalPath = $journalPath
        outputPath = $outputFull
        backupPath = $backupFull
        state = [string]$journal.state
    }
}

function Restore-PendingOutputTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputPath)
    $journal = Read-ValidatedOutputTransactionJournal -OutputPath $OutputPath
    if ($null -eq $journal) { return [pscustomobject]@{ status = 'none' } }
    $journalPath = $journal.journalPath
    $OutputPath = $journal.outputPath
    $backupExists = Test-Path -LiteralPath $journal.backupPath -PathType Leaf
    $outputExists = Test-Path -LiteralPath $OutputPath -PathType Leaf
    if ($backupExists -and -not $outputExists) {
        Move-Item -LiteralPath $journal.backupPath -Destination $OutputPath
        Remove-Item -LiteralPath $journalPath -Force
        return [pscustomobject]@{ status = 'restored'; output = $OutputPath }
    }
    if (-not $backupExists -and $outputExists -and $journal.state -eq 'committed') {
        Remove-Item -LiteralPath $journalPath -Force
        return [pscustomobject]@{ status = 'completed'; output = $OutputPath }
    }
    throw "recovery-needed: inspect output, backup, and journal before retrying: $journalPath"
}

function Invoke-OutputTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$ReplaceExisting
    )
    $CandidatePath = [IO.Path]::GetFullPath($CandidatePath)
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) { throw "Candidate does not exist: $CandidatePath" }
    $paths = Get-OutputTransactionPaths -OutputPath $OutputPath
    if (Test-Path -LiteralPath $paths.journal) { throw "recovery-needed: transaction journal already exists: $($paths.journal)" }
    $record = [ordered]@{ schemaVersion = 1; transactionId = [Guid]::NewGuid().ToString('N'); outputPath = $OutputPath; backupPath = $paths.backup; state = 'prepared'; updatedAt = [DateTimeOffset]::Now.ToString('o') }
    Write-OutputTransactionJournal -JournalPath $paths.journal -Record $record
    try {
        if (Test-Path -LiteralPath $OutputPath) {
            if (-not $ReplaceExisting) { throw "Output already exists: $OutputPath" }
            Move-Item -LiteralPath $OutputPath -Destination $paths.backup
            $record.state = 'backup-created'; $record.updatedAt = [DateTimeOffset]::Now.ToString('o')
            Write-OutputTransactionJournal -JournalPath $paths.journal -Record $record
        }
        Move-Item -LiteralPath $CandidatePath -Destination $OutputPath
        $record.state = 'committed'; $record.updatedAt = [DateTimeOffset]::Now.ToString('o')
        Write-OutputTransactionJournal -JournalPath $paths.journal -Record $record
        if (Test-Path -LiteralPath $paths.backup) { Remove-Item -LiteralPath $paths.backup -Force }
        Remove-Item -LiteralPath $paths.journal -Force
    } catch {
        if (-not (Test-Path -LiteralPath $OutputPath) -and (Test-Path -LiteralPath $paths.backup)) {
            Move-Item -LiteralPath $paths.backup -Destination $OutputPath
            Remove-Item -LiteralPath $paths.journal -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}
