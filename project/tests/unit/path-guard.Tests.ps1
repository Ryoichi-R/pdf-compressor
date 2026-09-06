BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'path-guard.ps1')
    $script:ExpectedToolRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\..\_internal' '..'))
}

Describe 'Assert-WritePathInsideTool (default tool root)' {
    It 'derives the tool root from the installed script location' {
        Get-PdfCompressorRoot | Should -Be $script:ExpectedToolRoot
    }
    # 受理側は path-guard がドライブレター root を要求するため Windows 専用（拒否側は非Windowsでも検証する）。
    It 'accepts path inside the installed pdf-compressor output directory' -Tag 'WindowsOnly' {
        $p = Join-Path $script:ExpectedToolRoot 'output\foo\bar.pdf'
        { Assert-WritePathInsideTool -TargetPath $p } | Should -Not -Throw
    }
    # 同上（ドライブレター root 前提の受理検証）。
    It 'accepts unborn nested path under output' -Tag 'WindowsOnly' {
        $p = Join-Path $script:ExpectedToolRoot 'output\drive-c-aaaaaaaaaaaa\Users\nobody\file.compressed.pdf'
        { Assert-WritePathInsideTool -TargetPath $p } | Should -Not -Throw
    }
    It 'rejects path outside pdf-compressor (a sibling directory)' {
        $outside = Join-Path (Split-Path -Parent $script:ExpectedToolRoot) 'sibling-project\out.pdf'
        { Assert-WritePathInsideTool -TargetPath $outside } | Should -Throw
    }
    It 'rejects path outside the installed tool root' {
        { Assert-WritePathInsideTool -TargetPath 'C:\temp\evil.pdf' } | Should -Throw
    }
    It 'rejects UNC paths' {
        { Assert-WritePathInsideTool -TargetPath '\\server\share\evil.pdf' } | Should -Throw
    }
    It 'rejects long-path prefix' {
        { Assert-WritePathInsideTool -TargetPath "\\?\$script:ExpectedToolRoot\out.pdf" } | Should -Throw
    }
    It 'rejects relative path' {
        { Assert-WritePathInsideTool -TargetPath 'output\foo.pdf' } | Should -Throw
    }
    It 'rejects empty path' {
        { Assert-WritePathInsideTool -TargetPath '' } | Should -Throw
    }
}

Describe 'Test-WritePathInsideTool' {
    # 同上（ドライブレター root 前提の受理検証）。
    It 'returns true for inside' -Tag 'WindowsOnly' {
        Test-WritePathInsideTool -TargetPath (Join-Path $script:ExpectedToolRoot 'output\x.pdf') | Should -BeTrue
    }
    It 'returns false for outside' {
        $outside = Join-Path (Split-Path -Parent $script:ExpectedToolRoot) 'sibling-project\x.pdf'
        Test-WritePathInsideTool -TargetPath $outside | Should -BeFalse
    }
}

Describe 'Assert-OutputPathLocal' {
    # 既存ドライブレター root の受理を検証するため Windows 専用。
    It 'accepts a path on the existing C: drive' -Tag 'WindowsOnly' {
        $p = 'C:\temp\pdfcomp-out\foo.pdf'
        { Assert-OutputPathLocal -TargetPath $p } | Should -Not -Throw
    }
    # 同上（ドライブレター root 前提）。
    It 'accepts an unborn nested path under an existing drive root' -Tag 'WindowsOnly' {
        $p = 'C:\temp\pdfcomp-unborn\sub\deeper\file.pdf'
        { Assert-OutputPathLocal -TargetPath $p } | Should -Not -Throw
    }
    It 'rejects UNC paths' {
        { Assert-OutputPathLocal -TargetPath '\\server\share\out' } | Should -Throw
    }
    It 'rejects \\?\ long-path prefix' {
        { Assert-OutputPathLocal -TargetPath '\\?\C:\out' } | Should -Throw
    }
    It 'rejects \\.\ device prefix' {
        { Assert-OutputPathLocal -TargetPath '\\.\PhysicalDrive0' } | Should -Throw
    }
    It 'rejects relative path' {
        { Assert-OutputPathLocal -TargetPath 'relative\out' } | Should -Throw
    }
    It 'rejects empty path' {
        { Assert-OutputPathLocal -TargetPath '' } | Should -Throw
    }
    It 'rejects path on a drive that does not exist' {
        # Find a drive letter that is not present.
        $usedLetters = (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
        $missing = ('Z','Y','X','W','V','U','T','S','R','Q') | Where-Object { $_ -notin $usedLetters } | Select-Object -First 1
        if ($null -eq $missing) { Set-ItResult -Skipped -Because 'No unused drive letter available'; return }
        { Assert-OutputPathLocal -TargetPath ("{0}:\out\file.pdf" -f $missing) } | Should -Throw
    }
}

Describe 'Test-OutputPathLocal' {
    # ドライブレターのローカルパス判定は Windows 固有。
    It 'returns true for local drive path' -Tag 'WindowsOnly' {
        Test-OutputPathLocal -TargetPath 'C:\temp\foo' | Should -BeTrue
    }
    It 'returns false for UNC path' {
        Test-OutputPathLocal -TargetPath '\\server\share\out' | Should -BeFalse
    }
}

Describe 'P1-13: PathGuardException is thrown (not a bare string)' {
    It 'Assert-WritePathInsideTool throws PathGuardException for outside paths' {
        $thrown = $null
        try { Assert-WritePathInsideTool -TargetPath 'C:\temp\evil.pdf' } catch { $thrown = $_.Exception }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.GetType().Name | Should -Be 'PathGuardException'
    }
    It 'Assert-OutputPathLocal throws PathGuardException for UNC' {
        $thrown = $null
        try { Assert-OutputPathLocal -TargetPath '\\server\share\out' } catch { $thrown = $_.Exception }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.GetType().Name | Should -Be 'PathGuardException'
    }
    It 'PathGuardException derives from System.Exception' {
        [PathGuardException].IsSubclassOf([System.Exception]) | Should -BeTrue
    }
}

# junction（NTFS reparse point）を作成して祖先チェックを検証するため Windows 専用。
Describe 'P1-7: ancestor reparse rejection (TOCTOU defense)' -Tag 'WindowsOnly' {
    BeforeAll {
        # Build: <tmp>\real\sub  + <tmp>\link -> <tmp>\real (junction)
        $script:JTmp = Join-Path ([System.IO.Path]::GetTempPath()) "pdfcomp-junc-$([Guid]::NewGuid().ToString('N'))"
        $script:JReal = Join-Path $script:JTmp 'real'
        $script:JReal_sub = Join-Path $script:JReal 'sub'
        $script:JLink = Join-Path $script:JTmp 'link'
        New-Item -ItemType Directory -Path $script:JReal_sub -Force | Out-Null
        # cmd /c mklink /J requires the link target to exist; the link itself
        # must not exist yet. Skip the spec gracefully if junctions aren't
        # creatable on this filesystem.
        $script:JunctionMade = $false
        try {
            cmd /c "mklink /J `"$script:JLink`" `"$script:JReal`"" 2>&1 | Out-Null
            $script:JunctionMade = Test-Path -LiteralPath $script:JLink
        } catch { $script:JunctionMade = $false }
    }
    AfterAll {
        if ($script:JTmp -and (Test-Path -LiteralPath $script:JTmp)) {
            cmd /c "rmdir `"$script:JLink`"" 2>&1 | Out-Null
            Remove-Item -LiteralPath $script:JTmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a write target whose ancestor is a junction' {
        if (-not $script:JunctionMade) { Set-ItResult -Skipped -Because 'junction creation failed (permissions?)'; return }
        $target = Join-Path $script:JLink 'child.pdf'
        $thrown = $null
        try { Assert-WritePathInsideTool -TargetPath $target } catch { $thrown = $_.Exception }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.GetType().Name | Should -Be 'PathGuardException'
        $thrown.Message | Should -Match 'reparse point'
    }
    It 'rejects an output root whose ancestor is a junction' {
        if (-not $script:JunctionMade) { Set-ItResult -Skipped -Because 'junction creation failed (permissions?)'; return }
        $target = Join-Path $script:JLink 'out\file.pdf'
        $thrown = $null
        try { Assert-OutputPathLocal -TargetPath $target } catch { $thrown = $_.Exception }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.GetType().Name | Should -Be 'PathGuardException'
    }
}
