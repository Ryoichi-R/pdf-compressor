BeforeAll {
    $script:toolRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:guiPs1     = Join-Path $script:toolRoot '_internal\gui.ps1'
    $script:editorCfg  = Join-Path $script:toolRoot '.editorconfig'
    $script:gitAttrTop = Join-Path (Split-Path -Parent $script:toolRoot) '.gitattributes'
}

Describe 'gui.ps1 file encoding' {
    It 'gui.ps1 exists' {
        Test-Path -LiteralPath $script:guiPs1 | Should -BeTrue
    }
    It 'is saved as UTF-8 with BOM (EF BB BF)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:guiPs1)
        $bytes.Length | Should -BeGreaterThan 3
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }
}

Describe 'editorconfig + gitattributes pin gui.ps1 encoding policy' {
    It '.editorconfig has a utf-8-bom rule for gui.ps1' {
        Test-Path -LiteralPath $script:editorCfg | Should -BeTrue
        $cfg = Get-Content -Raw -LiteralPath $script:editorCfg
        $cfg | Should -Match '_internal/gui\.ps1'
        $cfg | Should -Match 'utf-8-bom'
    }
    It '.gitattributes pins gui.ps1 line endings without unsupported working-tree encoding' {
        if (-not (Test-Path -LiteralPath $script:gitAttrTop -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'optional repository metadata is not present in a portable test root'
            return
        }
        $ga = Get-Content -Raw -LiteralPath $script:gitAttrTop
        $ga | Should -Match 'project/_internal/gui\.ps1'
        $ga | Should -Match 'project/_internal/gui\.ps1\s+text\s+eol=crlf'
        $ga | Should -Not -Match 'working-tree-encoding=UTF-8-BOM'
    }
}
