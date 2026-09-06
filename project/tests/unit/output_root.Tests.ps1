BeforeAll {
    $env:PDFCOMP_SKIP_MAIN = '1'
    . (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')

    $script:OutRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pdfcomp-outroot-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:OutRoot -Force | Out-Null

    function Resolve-TestOutputPath {
        param(
            [Parameter(Mandatory)][System.IO.FileInfo]$Pdf,
            [Parameter(Mandatory)][string]$SourceRoot,
            [Parameter(Mandatory)][string]$OutputRoot,
            [Parameter(Mandatory)][bool]$UseOutsideOutputRoot,
            [Parameter(Mandatory)][ref]$SeenMap
        )
        $context = New-OutputPathContext -SourceRoot $SourceRoot -OutputRoot $OutputRoot -UseOutsideOutputRoot $UseOutsideOutputRoot
        Resolve-OutputPath -Pdf $Pdf -Context $context -SeenMap $SeenMap
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:OutRoot) {
        Remove-Item -LiteralPath $script:OutRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:PDFCOMP_SKIP_MAIN -ErrorAction SilentlyContinue
}

# このファイルは Windows のパス意味論（ドライブレター root、末尾スペース/ドットの禁止、
# バックスラッシュ区切り）に対する Resolve-OutputPath の挙動を検証する。
# 非 Windows では path-guard が drive-letter root を要求して例外になり前提が成立しない。
Describe 'Resolve-OutputPath sanitization collision (P1-1)' -Tag 'WindowsOnly' {
    BeforeEach {
        $script:SeenMap = @{}
    }

    It 'two source files whose stems sanitize to the same name resolve to distinct outputs' {
        # 'foo .pdf' (trailing space in stem) and 'foo.pdf' both sanitize to
        # safeStem='foo'. The trailing space is stripped by ConvertTo-SafeSegment.
        $pdfA = [System.IO.FileInfo]::new('C:\src\dir\foo .pdf')
        $pdfB = [System.IO.FileInfo]::new('C:\src\dir\foo.pdf')

        $outA = Resolve-TestOutputPath -Pdf $pdfA -SourceRoot 'C:\src\dir' -OutputRoot $script:OutRoot -UseOutsideOutputRoot $true -SeenMap ([ref]$script:SeenMap)
        $outB = Resolve-TestOutputPath -Pdf $pdfB -SourceRoot 'C:\src\dir' -OutputRoot $script:OutRoot -UseOutsideOutputRoot $true -SeenMap ([ref]$script:SeenMap)

        $outA | Should -Not -BeNullOrEmpty
        $outB | Should -Not -BeNullOrEmpty
        $outA | Should -Not -Be $outB
        # Same registered key only once, both leaves stored.
        $script:SeenMap.Keys.Count | Should -Be 2
        # The collided file (second one) gets a ~hash12 suffix on the stem.
        $leafA = Split-Path -Leaf $outA
        $leafB = Split-Path -Leaf $outB
        ($leafA + $leafB) | Should -Match 'foo~[0-9a-f]{12}\.compressed\.pdf'
    }

    It 'two source files in differently-named directories that sanitize to the same dir resolve distinctly' {
        # 'a .' (trailing space+dot trimmed) and 'a' both sanitize to 'a'.
        $pdfA = [System.IO.FileInfo]::new('C:\src\dir\a .\file.pdf')
        $pdfB = [System.IO.FileInfo]::new('C:\src\dir\a\file.pdf')

        $outA = Resolve-TestOutputPath -Pdf $pdfA -SourceRoot 'C:\src\dir' -OutputRoot $script:OutRoot -UseOutsideOutputRoot $true -SeenMap ([ref]$script:SeenMap)
        $outB = Resolve-TestOutputPath -Pdf $pdfB -SourceRoot 'C:\src\dir' -OutputRoot $script:OutRoot -UseOutsideOutputRoot $true -SeenMap ([ref]$script:SeenMap)

        $outA | Should -Not -Be $outB
    }

    It 'same source file processed twice does not double-register (idempotent)' {
        $pdf = [System.IO.FileInfo]::new('C:\src\dir\only.pdf')
        $out1 = Resolve-TestOutputPath -Pdf $pdf -SourceRoot 'C:\src\dir' -OutputRoot $script:OutRoot -UseOutsideOutputRoot $true -SeenMap ([ref]$script:SeenMap)
        $out2 = Resolve-TestOutputPath -Pdf $pdf -SourceRoot 'C:\src\dir' -OutputRoot $script:OutRoot -UseOutsideOutputRoot $true -SeenMap ([ref]$script:SeenMap)

        $out1 | Should -Be $out2
        $script:SeenMap.Keys.Count | Should -Be 1
    }

    It 'default OutputRoot branch also detects sanitization collisions (UseOutsideOutputRoot=$false)' {
        # Two files with stems that collapse to the same sanitized name.
        $pdfA = [System.IO.FileInfo]::new('C:\src\dir\bar .pdf')
        $pdfB = [System.IO.FileInfo]::new('C:\src\dir\bar.pdf')

        # Default branch calls Assert-WritePathInsideTool; stub it to bypass
        # the tool-root requirement so we can use a temp output root.
        function Assert-WritePathInsideTool { param($TargetPath) return $TargetPath }

        $outA = Resolve-TestOutputPath -Pdf $pdfA -SourceRoot $pdfA.DirectoryName -OutputRoot $script:OutRoot -UseOutsideOutputRoot $false -SeenMap ([ref]$script:SeenMap)
        $outB = Resolve-TestOutputPath -Pdf $pdfB -SourceRoot $pdfB.DirectoryName -OutputRoot $script:OutRoot -UseOutsideOutputRoot $false -SeenMap ([ref]$script:SeenMap)

        $outA | Should -Not -Be $outB
    }
}

Describe 'Resolve-OutputPath mirroring under explicit OutputRoot (P1-1 regression)' -Tag 'WindowsOnly' {
    BeforeEach {
        $script:SeenMap = @{}
    }

    It 'preserves relative subdirectories under -OutputRoot' {
        $pdf = [System.IO.FileInfo]::new('C:\src\dir\sub\nested\paper.pdf')
        $out = Resolve-TestOutputPath -Pdf $pdf -SourceRoot 'C:\src\dir' -OutputRoot $script:OutRoot -UseOutsideOutputRoot $true -SeenMap ([ref]$script:SeenMap)

        $out | Should -Match ([regex]::Escape((Join-Path $script:OutRoot 'sub\nested\paper.compressed.pdf')))
    }

    It 'lands a single-file input directly under -OutputRoot when SourceRoot equals parent' {
        $pdf = [System.IO.FileInfo]::new('C:\src\dir\onlyfile.pdf')
        $out = Resolve-TestOutputPath -Pdf $pdf -SourceRoot 'C:\src\dir' -OutputRoot $script:OutRoot -UseOutsideOutputRoot $true -SeenMap ([ref]$script:SeenMap)

        # SourceRoot==parent so relDir is empty -> output goes directly under root.
        $out | Should -Be (Join-Path $script:OutRoot 'onlyfile.compressed.pdf')
    }
}
