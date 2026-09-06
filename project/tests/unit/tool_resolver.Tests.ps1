BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'tool-resolver.ps1')
}

Describe 'P1-12: shared tool-resolver SSoT' {
    It 'exposes Find-ToolExecutable and Get-ToolSearchRoots' {
        Get-Command Find-ToolExecutable  | Should -Not -BeNullOrEmpty
        Get-Command Get-ToolSearchRoots  | Should -Not -BeNullOrEmpty
    }

    It 'returns $null for a non-existent tool name' {
        Find-ToolExecutable -Name 'definitely-not-a-real-tool-xyz' | Should -BeNullOrEmpty
    }

    It 'returns the cached path from -ExtraCandidates when PATH lookup misses' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "fake-exe-$([Guid]::NewGuid().ToString('N')).exe"
        '' | Set-Content -LiteralPath $fake
        try {
            $hit = Find-ToolExecutable -Name 'definitely-not-real-xyz123' -ExtraCandidates @($fake)
            $hit | Should -Be (Resolve-Path -LiteralPath $fake).Path
        } finally {
            Remove-Item -LiteralPath $fake -ErrorAction SilentlyContinue
        }
    }

    It 'ignores cached command wrappers so native .exe tools handle non-ASCII paths' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "fake-cmd-$([Guid]::NewGuid().ToString('N')).cmd"
        '' | Set-Content -LiteralPath $fake
        try {
            Find-ToolExecutable -Name 'definitely-not-real-xyz123' -ExtraCandidates @($fake) | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $fake -ErrorAction SilentlyContinue
        }
    }

    It 'search roots include both WinGet\Packages and WinGet\Links (the original drift point)' {
        $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'tool-resolver.ps1')
        $src | Should -Match 'WinGet\\Packages'
        $src | Should -Match 'WinGet\\Links'
    }
}

Describe 'P1-12: callers no longer duplicate the resolver body' {
    It 'compress.ps1 dot-sources tool-resolver.ps1' {
        $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $src | Should -Match "\.\s*\(Join-Path\s+\`$script:ScriptDir\s+'tool-resolver\.ps1'\)"
        # The old in-file resolver must be gone.
        $src | Should -Not -Match 'function\s+Resolve-ExternalTool'
        $src | Should -Match 'Find-ToolExecutable\s+-Name'
    }

    It 'setup-dependencies.ps1 delegates to Find-ToolExecutable instead of inlining the scan' {
        $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'setup-dependencies.ps1')
        $src | Should -Match "\.\s*\(Join-Path\s+\`$scriptDir\s+'tool-resolver\.ps1'\)"
        $src | Should -Match 'return\s+Find-ToolExecutable\s+-Name\s+\$Cmd'
        # The original duplicated body had its own $roots = @(...) literal — must be gone.
        $src | Should -Not -Match 'WinGet\\Packages'
    }
}
