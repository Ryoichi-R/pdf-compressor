# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Shared JSON Lines appender. Single write path used by both the CLI child
    (compress.ps1) and the GUI parent (gui.ps1 cancel handler) so the two
    cannot race each other (P1-9).

.DESCRIPTION
    The old code had two independent writers:
      - compress.ps1: Add-Content -Encoding UTF8
      - gui.ps1:      direct FileStream(OpenOrCreate, ReadWrite, FileShare.Read)
    Neither held a cross-process lock, and a taskkill /F followed by a
    500ms-polling "flush wait" did not actually guarantee anything because the
    forced-killed child never flushes after death.

    Write-JsonlRecord serializes both writers through a Global\ named Mutex
    keyed by the canonical log-file path, so:
      - In-flight writes from either process complete atomically.
      - The cancel-aborted line cannot collide with the final result line.
      - Abandoned mutex (caller killed) returns ownership cleanly to the next
        waiter via AbandonedMutexException, which we treat as acquired.

.OUTPUTS
    None. Throws on I/O failure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JsonlMutexName {
    param([Parameter(Mandatory)][string]$Path)
    $canonical = [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    $hex = -join ($h | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') })
    # Global\ prefix so the lock spans interactive sessions (GUI parent and CLI child).
    return "Global\pdfcomp-jsonl-$hex"
}

function Write-JsonlRecord {
    <#
    .PARAMETER Path
        Absolute path to the .jsonl file. Created if missing.
    .PARAMETER Record
        Any object that ConvertTo-Json can serialize. Written compact + LF.
    .PARAMETER TimeoutMs
        How long to wait for the cross-process mutex. Defaults to 5 seconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Record,
        [int]$TimeoutMs = 5000
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $mutexName = Get-JsonlMutexName -Path $Path
    $created = $false
    $mutex = [System.Threading.Mutex]::new($false, $mutexName, [ref]$created)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMs)
        } catch [System.Threading.AbandonedMutexException] {
            # Previous holder died without releasing — ownership is now ours.
            $acquired = $true
        }
        if (-not $acquired) {
            throw "jsonl-writer: timed out (${TimeoutMs}ms) acquiring '$mutexName' for '$Path'."
        }

        $line = ($Record | ConvertTo-Json -Compress)
        $fs = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`n")
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush($true)
        } finally {
            $fs.Dispose()
        }
    } finally {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
    }
}
