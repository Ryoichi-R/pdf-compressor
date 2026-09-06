BeforeAll {
    $env:PDFCOMP_SKIP_MAIN = '1'
    . (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
}

AfterAll {
    Remove-Item Env:PDFCOMP_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'P1-8: Invoke-WorkDirCleanup respects live owner PIDs' {
    BeforeEach {
        $script:WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pdfcomp-work-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null
    }
    AfterEach {
        if ($script:WorkRoot -and (Test-Path -LiteralPath $script:WorkRoot)) {
            Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves a stale (>24h) subdir whose PID is still alive (current process)' {
        $aliveDir = Join-Path $script:WorkRoot ("{0}-{1}" -f $PID, ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $aliveDir -Force | Out-Null
        # Force the LastWriteTime past the 24h TTL window.
        (Get-Item -LiteralPath $aliveDir).LastWriteTime = (Get-Date).AddDays(-2)

        Invoke-WorkDirCleanup

        Test-Path -LiteralPath $aliveDir | Should -BeTrue
    }

    It 'removes a stale subdir whose owner PID is dead' {
        # Pick a high PID very unlikely to be live (0 is reserved on Windows).
        $deadPid = 99999
        while (Get-Process -Id $deadPid -ErrorAction SilentlyContinue) { $deadPid++ }
        $deadDir = Join-Path $script:WorkRoot ("{0}-{1}" -f $deadPid, ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $deadDir -Force | Out-Null
        (Get-Item -LiteralPath $deadDir).LastWriteTime = (Get-Date).AddDays(-2)

        Invoke-WorkDirCleanup

        Test-Path -LiteralPath $deadDir | Should -BeFalse
    }

    It 'removes legacy subdirs that do not match the [pid]-[guid] pattern' {
        $legacyDir = Join-Path $script:WorkRoot 'legacy-format-no-pid'
        New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
        (Get-Item -LiteralPath $legacyDir).LastWriteTime = (Get-Date).AddDays(-2)

        Invoke-WorkDirCleanup

        Test-Path -LiteralPath $legacyDir | Should -BeFalse
    }

    It 'leaves fresh (<24h) directories alone regardless of PID liveness' {
        $freshDir = Join-Path $script:WorkRoot ("99999-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $freshDir -Force | Out-Null
        # LastWriteTime defaults to now -> fresh.

        Invoke-WorkDirCleanup

        Test-Path -LiteralPath $freshDir | Should -BeTrue
    }
}

Describe 'P1-8: Test-WorkDirOwnerAlive helper' {
    It 'reports current PID as alive' {
        Test-WorkDirOwnerAlive -DirName ("{0}-deadbeef" -f $PID) | Should -BeTrue
    }
    It 'reports an unused high PID as not alive' {
        $deadPid = 99999
        while (Get-Process -Id $deadPid -ErrorAction SilentlyContinue) { $deadPid++ }
        Test-WorkDirOwnerAlive -DirName ("{0}-x" -f $deadPid) | Should -BeFalse
    }
    It 'reports legacy (no PID prefix) names as not alive (will be reclaimed)' {
        Test-WorkDirOwnerAlive -DirName 'just-some-name' | Should -BeFalse
    }
}
