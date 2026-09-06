BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal\output-transaction.ps1')
}

Describe 'durable output transaction' {
    It 'replaces an existing output and removes transaction artifacts' {
        $output = Join-Path $TestDrive 'result.pdf'
        $candidate = Join-Path $TestDrive 'candidate.pdf'
        [IO.File]::WriteAllText($output, 'old')
        [IO.File]::WriteAllText($candidate, 'new')
        Invoke-OutputTransaction -CandidatePath $candidate -OutputPath $output -ReplaceExisting
        Get-Content -LiteralPath $output -Raw | Should -Be 'new'
        Test-Path -LiteralPath ($output + '.pdfcomp-transaction.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'result.pdf.bak.*').Count | Should -Be 0
    }

    It 'restores a backup when a crash left no formal output' {
        $output = Join-Path $TestDrive 'recover.pdf'
        $backup = $output + '.bak.' + ('a' * 32)
        $journal = $output + '.pdfcomp-transaction.json'
        [IO.File]::WriteAllText($backup, 'old')
        [ordered]@{ schemaVersion=1; outputPath=$output; backupPath=$backup; state='backup-created' } | ConvertTo-Json | Set-Content -LiteralPath $journal
        (Restore-PendingOutputTransaction -OutputPath $output).status | Should -Be 'restored'
        Get-Content -LiteralPath $output -Raw | Should -Be 'old'
        Test-Path -LiteralPath $journal | Should -BeFalse
    }

    It 'fails closed when output and backup both exist' {
        $output = Join-Path $TestDrive 'ambiguous.pdf'
        $backup = $output + '.bak.' + ('b' * 32)
        $journal = $output + '.pdfcomp-transaction.json'
        [IO.File]::WriteAllText($output, 'new')
        [IO.File]::WriteAllText($backup, 'old')
        [ordered]@{ schemaVersion=1; outputPath=$output; backupPath=$backup; state='committed' } | ConvertTo-Json | Set-Content -LiteralPath $journal
        { Restore-PendingOutputTransaction -OutputPath $output } | Should -Throw '*recovery-needed*'
        Test-Path -LiteralPath $backup | Should -BeTrue
    }

    It 'finishes cleanup when a committed journal has output and no backup' {
        $output = Join-Path $TestDrive 'committed.pdf'
        $backup = $output + '.bak.' + ('c' * 32)
        $journal = $output + '.pdfcomp-transaction.json'
        [IO.File]::WriteAllText($output, 'new')
        [ordered]@{ schemaVersion=1; outputPath=$output; backupPath=$backup; state='committed' } | ConvertTo-Json | Set-Content -LiteralPath $journal
        (Restore-PendingOutputTransaction -OutputPath $output).status | Should -Be 'completed'
        Get-Content -LiteralPath $output -Raw | Should -Be 'new'
        Test-Path -LiteralPath $journal | Should -BeFalse
    }

    It 'rejects malformed state and path-mismatch journals without deleting artifacts' {
        $output = Join-Path $TestDrive 'invalid.pdf'
        $backup = $output + '.bak.' + ('d' * 32)
        $journal = $output + '.pdfcomp-transaction.json'
        [IO.File]::WriteAllText($output, 'new')
        [IO.File]::WriteAllText($backup, 'old')
        [ordered]@{ schemaVersion=1; outputPath=$output; backupPath=$backup; state='unknown' } | ConvertTo-Json | Set-Content -LiteralPath $journal
        { Restore-PendingOutputTransaction -OutputPath $output } | Should -Throw '*invalid output transaction journal*'
        Test-Path -LiteralPath $output | Should -BeTrue
        Test-Path -LiteralPath $backup | Should -BeTrue

        [ordered]@{ schemaVersion=1; outputPath=(Join-Path $TestDrive 'other.pdf'); backupPath=$backup; state='committed' } | ConvertTo-Json | Set-Content -LiteralPath $journal
        { Restore-PendingOutputTransaction -OutputPath $output } | Should -Throw '*path mismatch*'
        Test-Path -LiteralPath $backup | Should -BeTrue
    }

    It 'rejects a journal that points its backup outside the output directory' {
        $dir = Join-Path $TestDrive 'output-dir'
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $output = Join-Path $dir 'result.pdf'
        $external = Join-Path $TestDrive ('external.pdf.bak.' + ('e' * 32))
        $journal = $output + '.pdfcomp-transaction.json'
        [IO.File]::WriteAllText($external, 'must-remain')
        [ordered]@{ schemaVersion=1; outputPath=$output; backupPath=$external; state='backup-created' } | ConvertTo-Json | Set-Content -LiteralPath $journal
        { Restore-PendingOutputTransaction -OutputPath $output } | Should -Throw '*unsafe output transaction backup path*'
        Get-Content -LiteralPath $external -Raw | Should -Be 'must-remain'
        Test-Path -LiteralPath $journal | Should -BeTrue
    }

    It 'fails closed for every ambiguous file-presence state' -ForEach @(
        @{Name='prepared-output-only';State='prepared';Output=$true;Backup=$false},
        @{Name='prepared-neither';State='prepared';Output=$false;Backup=$false},
        @{Name='backup-created-both';State='backup-created';Output=$true;Backup=$true},
        @{Name='committed-neither';State='committed';Output=$false;Backup=$false}
    ) {
        $output = Join-Path $TestDrive ($Name + '.pdf')
        $backup = $output + '.bak.' + ('f' * 32)
        $journal = $output + '.pdfcomp-transaction.json'
        if ($Output) { [IO.File]::WriteAllText($output, 'new') }
        if ($Backup) { [IO.File]::WriteAllText($backup, 'old') }
        [ordered]@{ schemaVersion=1; outputPath=$output; backupPath=$backup; state=$State } | ConvertTo-Json | Set-Content -LiteralPath $journal
        { Restore-PendingOutputTransaction -OutputPath $output } | Should -Throw '*recovery-needed*'
        Test-Path -LiteralPath $journal | Should -BeTrue
    }
}
