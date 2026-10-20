BeforeAll {
    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "pdfcomp-enum-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    # Build a synthetic folder with mixed file names.
    'x' | Set-Content -LiteralPath (Join-Path $script:TmpDir 'a.pdf')
    'x' | Set-Content -LiteralPath (Join-Path $script:TmpDir 'b.compressed.pdf')
    New-Item -ItemType Directory -Path (Join-Path $script:TmpDir 'sub') -Force | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $script:TmpDir 'sub\c.pdf')
    'x' | Set-Content -LiteralPath (Join-Path $script:TmpDir 'sub\d.compressed.pdf')
}

AfterAll {
    if (Test-Path -LiteralPath $script:TmpDir) {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'PDF enumeration policy (extracted logic mirroring compress.ps1)' {
    It 'recursive enumeration excludes *.compressed.pdf' {
        $outputRootFull = (Join-Path $script:TmpDir 'output').ToLowerInvariant()
        $files = Get-ChildItem -LiteralPath $script:TmpDir -Recurse -File -Filter '*.pdf' |
            Where-Object {
                $full = $_.FullName.ToLowerInvariant()
                ($_.Name -notlike '*.compressed.pdf') -and (-not $full.StartsWith($outputRootFull))
            }
        $names = $files | ForEach-Object { $_.Name } | Sort-Object
        $names | Should -Be @('a.pdf','c.pdf')
    }
}
