BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\_internal' 'jsonl-writer.ps1')

    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "pdfcomp-jsonl-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
}

AfterAll {
    if ($script:TmpDir -and (Test-Path -LiteralPath $script:TmpDir)) {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Write-JsonlRecord basic semantics' {
    It 'creates the file when missing and appends one line per call' {
        $p = Join-Path $script:TmpDir 'basic.jsonl'
        Write-JsonlRecord -Path $p -Record @{ n = 1 }
        Write-JsonlRecord -Path $p -Record @{ n = 2 }
        (Get-Content -LiteralPath $p).Count | Should -Be 2
    }
    It 'emits compact JSON terminated by LF' {
        $p = Join-Path $script:TmpDir 'compact.jsonl'
        Write-JsonlRecord -Path $p -Record ([ordered]@{ a = 1; b = 'x' })
        $raw = [System.IO.File]::ReadAllBytes($p)
        $raw[-1] | Should -Be 10  # 0x0A
        $text = [System.Text.Encoding]::UTF8.GetString($raw).TrimEnd("`n")
        $text | Should -Be '{"a":1,"b":"x"}'
    }
    It 'creates the parent directory when missing' {
        $p = Join-Path $script:TmpDir 'sub\nested\new.jsonl'
        Write-JsonlRecord -Path $p -Record @{ x = 1 }
        Test-Path -LiteralPath $p | Should -BeTrue
    }
}

Describe 'P1-9: concurrent appenders do not corrupt the file' {
    It 'two parallel jobs writing 50 lines each yield 100 well-formed lines' {
        $p = Join-Path $script:TmpDir 'concurrent.jsonl'
        $writer = (Join-Path $PSScriptRoot '..\..\_internal' 'jsonl-writer.ps1')

        $sb = {
            param($Writer, $Path, $Tag, $Count)
            . $Writer
            for ($i = 0; $i -lt $Count; $i++) {
                Write-JsonlRecord -Path $Path -Record ([ordered]@{ tag = $Tag; i = $i })
            }
        }
        $j1 = Start-Job -ScriptBlock $sb -ArgumentList $writer, $p, 'A', 50
        $j2 = Start-Job -ScriptBlock $sb -ArgumentList $writer, $p, 'B', 50
        Wait-Job $j1, $j2 | Out-Null
        Receive-Job $j1, $j2 | Out-Null
        Remove-Job $j1, $j2

        $lines = Get-Content -LiteralPath $p
        $lines.Count | Should -Be 100
        # Every line must be valid JSON with the expected shape.
        foreach ($ln in $lines) {
            { $null = $ln | ConvertFrom-Json } | Should -Not -Throw
        }
        $tags = $lines | ForEach-Object { ($_ | ConvertFrom-Json).tag } | Sort-Object -Unique
        ($tags -join ',') | Should -Be 'A,B'
    }
}

Describe 'P1-9: callers use the helper (no inline append/FileStream)' {
    It 'compress.ps1 routes Write-ResultLine through Write-JsonlRecord' {
        $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'compress.ps1')
        $src | Should -Match 'Write-JsonlRecord -Path \$Jsonl -Record \$rec'
        # The old per-record Add-Content sink must be gone.
        $src | Should -Not -Match 'Add-Content -LiteralPath \$Jsonl -Value'
    }
    It 'gui.ps1 routes Write-AbortedJsonl through Write-JsonlRecord' {
        $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\_internal' 'gui.ps1')
        $src | Should -Match 'Write-JsonlRecord -Path \$script:LogJsonl'
        # The old hand-rolled FileStream open must be gone.
        $src | Should -Not -Match '\[System\.IO\.FileStream\]::new\('
    }
}
