BeforeAll {
    $script:toolRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:guiBat     = Join-Path $script:toolRoot 'scripts\launchers\gui.bat'
    $script:compressBat = Join-Path $script:toolRoot 'scripts\launchers\compress-dev.bat'
    $script:installBat  = Join-Path $script:toolRoot 'scripts\setup\install-dependencies.bat'
    $script:guiText      = Get-Content -Raw -LiteralPath $script:guiBat
    $script:compressText = Get-Content -Raw -LiteralPath $script:compressBat
    $script:installText  = Get-Content -Raw -LiteralPath $script:installBat
}

Describe 'pwsh required: powershell.exe fallback removed' {
    It 'gui.bat has no PSEXE=powershell fallback' {
        $script:guiText | Should -Not -Match 'PSEXE=powershell'
    }
    It 'compress.bat has no PSEXE=powershell fallback' {
        $script:compressText | Should -Not -Match 'PSEXE=powershell'
    }
    It 'install.bat has no PSEXE=powershell fallback' {
        $script:installText | Should -Not -Match 'PSEXE=powershell'
    }
}

Describe 'pwsh required: where pwsh detection branch present' {
    It 'gui.bat checks for pwsh and exits 2 if missing' {
        $script:guiText | Should -Match 'where pwsh'
        $script:guiText | Should -Match 'exit /b 2'
    }
    It 'compress.bat checks for pwsh and exits 2 if missing' {
        $script:compressText | Should -Match 'where pwsh'
        $script:compressText | Should -Match 'exit /b 2'
    }
    It 'install.bat checks for pwsh and exits 2 if missing' {
        $script:installText | Should -Match 'where pwsh'
        $script:installText | Should -Match 'exit /b 2'
    }
}

Describe 'pwsh-missing branch pause policy' {
    BeforeAll {
        # `if errorlevel 1 (...` から最初の `pwsh` ブロック終端までを抽出する。
        # 行頭 (空白許容) の `)` を終端マーカーとして使う。
        function Get-PwshMissingBranch {
            param([string]$Text)
            $m = [regex]::Match($Text, '(?ms)where\s+pwsh\s*>nul\s*2>&1\s*\r?\nif\s+errorlevel\s+1\s*\((.*?)^\s*\)\s*$')
            if ($m.Success) { return $m.Groups[1].Value }
            return $null
        }
        $script:guiBranch      = Get-PwshMissingBranch $script:guiText
        $script:compressBranch = Get-PwshMissingBranch $script:compressText
        $script:installBranch  = Get-PwshMissingBranch $script:installText
    }

    It 'extracts pwsh-missing branch from each bat' {
        $script:guiBranch      | Should -Not -BeNullOrEmpty
        $script:compressBranch | Should -Not -BeNullOrEmpty
        $script:installBranch  | Should -Not -BeNullOrEmpty
    }

    It 'gui.bat pauses before exit 2 on pwsh-missing (double-click friendly)' {
        $script:guiBranch | Should -Match '(?ms)pause[\s\S]*exit /b 2'
    }

    It 'compress.bat does not pause on pwsh-missing branch (CLI/automation friendly)' {
        $script:compressBranch | Should -Not -Match 'pause'
        $script:compressBranch | Should -Match 'exit /b 2'
    }

    It 'install.bat does not pause on pwsh-missing branch (CLI/automation friendly)' {
        $script:installBranch | Should -Not -Match 'pause'
        $script:installBranch | Should -Match 'exit /b 2'
    }
}
