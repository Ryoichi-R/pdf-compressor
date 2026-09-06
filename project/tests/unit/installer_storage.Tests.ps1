BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\installer\Installer.Storage.ps1')
}

Describe 'installer capacity and retention contract' {
    It 'uses 2Enew plus headroom for a fresh install' {
        $plan = Get-InstallerCapacityPlan -NewPayloadBytes 400MB -CurrentManagedBytes 0 -ExistingBackupBytes 0 -AvailableBytes 2GB -IsUpdate:$false
        $plan.headroomBytes | Should -Be 256MB
        $plan.requiredAdditionalBytes | Should -Be (800MB + 256MB)
        $plan.sufficient | Should -BeTrue
    }

    It 'uses Enew plus Ecurrent plus headroom for an update' {
        $plan = Get-InstallerCapacityPlan -NewPayloadBytes 400MB -CurrentManagedBytes 390MB -ExistingBackupBytes 390MB -AvailableBytes 900MB -IsUpdate:$true
        $plan.requiredAdditionalBytes | Should -Be (790MB + 256MB)
        $plan.predictedTotalPeakBytes | Should -Be (390MB + 390MB + 400MB + 390MB + 256MB)
        $plan.sufficient | Should -BeFalse
    }

    It 'lists older backups without deleting them' {
        $root = Join-Path $TestDrive 'backups'
        $old = Join-Path $root 'previous-20260101T000000000'
        $new = Join-Path $root 'previous-20260102T000000000'
        [IO.Directory]::CreateDirectory($old) | Out-Null
        [IO.Directory]::CreateDirectory($new) | Out-Null
        [IO.File]::WriteAllText((Join-Path $old 'old.txt'), 'old')
        $plan = Get-InstallerBackupRetentionPlan -BackupRoot $root -PreferredKeepPath $new
        $plan.keep | Should -Be $new
        $plan.cleanupCandidates | Should -Contain $old
        $plan.requiresApproval | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $old 'old.txt') | Should -BeTrue
    }

    It 'deletes only explicitly approved marker-bound backup candidates' {
        $root = Join-Path $TestDrive 'approved-backups'
        $old = Join-Path $root 'previous-20260101T000000000'
        $new = Join-Path $root 'previous-20260102T000000000'
        foreach ($path in @($old,$new)) {
            [IO.Directory]::CreateDirectory($path) | Out-Null
            [IO.File]::WriteAllText((Join-Path $path '.pdf-compressor-install.json'), '{"productId":"pdf-compressor"}')
        }
        $removed = @(Remove-ApprovedInstallerBackups -BackupRoot $root -Candidates @($old))
        $removed | Should -Be @($old)
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $new | Should -BeTrue
    }

    It 'rejects unmarked, nested, and over-limit cleanup targets before deletion' {
        $root = Join-Path $TestDrive 'rejected-backups'
        $unmarked = Join-Path $root 'previous-20260101T000000000'
        $nested = Join-Path $unmarked 'previous-20260102T000000000'
        [IO.Directory]::CreateDirectory($nested) | Out-Null
        { Remove-ApprovedInstallerBackups -BackupRoot $root -Candidates @($unmarked) } | Should -Throw '*no install marker*'
        { Remove-ApprovedInstallerBackups -BackupRoot $root -Candidates @($nested) } | Should -Throw '*Unsafe backup cleanup target*'
        $many = 1..9 | ForEach-Object { Join-Path $root ("previous-202601{0:D2}T000000000" -f $_) }
        { Remove-ApprovedInstallerBackups -BackupRoot $root -Candidates $many } | Should -Throw '*exceeds the limit*'
        Test-Path -LiteralPath $unmarked | Should -BeTrue
    }
}
