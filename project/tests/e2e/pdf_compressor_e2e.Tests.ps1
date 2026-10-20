Set-StrictMode -Version Latest

BeforeAll {
    $internalRoot = Join-Path $PSScriptRoot '..\..\_internal'
    $projectRoot = Split-Path -Parent $internalRoot
    $fixtureRoot = Join-Path $projectRoot 'tests\fixtures\pdf'
    $fixturePath = Join-Path $fixtureRoot 'minimal-text.pdf'
    $provenancePath = Join-Path $fixtureRoot 'manifest.json'
    $compressPath = Join-Path $internalRoot 'compress.ps1'
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    . (Join-Path $internalRoot 'tool-resolver.ps1')
    . (Join-Path $internalRoot 'pdf-structure.ps1')
    . (Join-Path $internalRoot 'inspect_pdf_features.ps1')
    $toolCommands = @{
        qpdf = @('qpdf')
        ghostscript = @('gswin64c','gs','ghostscript')
        pdfinfo = @('pdfinfo')
    }
    $toolPaths = @{}
    $missingTools = @()
    foreach ($entry in $toolCommands.GetEnumerator()) {
        $found = $null
        foreach ($name in $entry.Value) {
            $found = Find-ToolExecutable -Name $name
            if ($found) { break }
        }
        if ($found) { $toolPaths[$entry.Key] = $found } else { $missingTools += $entry.Key }
    }
    $missingMetadataTools = @(@('qpdf','pdfinfo') | Where-Object { $missingTools -contains $_ })
    $missingCompressionTools = @(@('qpdf','ghostscript','pdfinfo') | Where-Object { $missingTools -contains $_ })
}

Describe 'Tier 1 real PDF E2E' -Tag 'E2E','ExternalTool' {
    It 'matches fixture provenance and Poppler page metadata' {
        if ($missingMetadataTools.Count -gt 0) {
            Set-ItResult -Skipped -Because ("missing external tools: " + ($missingMetadataTools -join ', '))
            return
        }
        (Test-Path -LiteralPath $fixturePath -PathType Leaf) | Should -BeTrue
        $provenance = Get-Content -LiteralPath $provenancePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash.ToLowerInvariant()
        $actualHash | Should -Be $provenance.sha256
        $info = @(& $toolPaths.pdfinfo '--' $fixturePath 2>&1)
        $LASTEXITCODE | Should -Be 0
        ($info -join "`n") | Should -Match '(?m)^Pages:\s+1'
        $provenance.expected.expected_mode | Should -Be 'auto'
        $provenance.expected.expected_strategy | Should -Be 'qpdf-lossless'
        $snapshot = Get-PdfStructureSnapshot -PdfPath $fixturePath -PdfInfoExe $toolPaths.pdfinfo -QpdfExe $toolPaths.qpdf -PageCount ([int]$provenance.expected.page_count)
        $snapshot.status | Should -Be 'verified'
        @($snapshot.pages | ForEach-Object { [int]$_.rotate }) | Should -Be @($provenance.expected.rotation)
        @($snapshot.pages[0].media_box) | Should -Be @($provenance.expected.preserve_structure.media_box)
        @($snapshot.pages[0].crop_box) | Should -Be @($provenance.expected.preserve_structure.crop_box)
        $features = Get-PdfFeatures -PdfPath $fixturePath -QpdfExe $toolPaths.qpdf
        foreach ($property in $provenance.expected.features.PSObject.Properties) {
            $features.features[$property.Name].state | Should -Be ([string]$property.Value)
        }
    }

    It 'runs a real compression process and records JSONL plus StatusJson' {
        if ($missingCompressionTools.Count -gt 0) {
            Set-ItResult -Skipped -Because ("missing external tools: " + ($missingCompressionTools -join ', '))
            return
        }
        if (-not $pwsh) {
            Set-ItResult -Skipped -Because 'pwsh is not available'
            return
        }
        $outputRoot = Join-Path $TestDrive 'output'
        $evidenceRoot = Join-Path $projectRoot ('_work\e2e-' + [Guid]::NewGuid().ToString('N'))
        $logPath = Join-Path $evidenceRoot 'run.jsonl'
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
        try {
            $args = @('-NoProfile','-NonInteractive','-File',$compressPath,'-InputPath',$fixturePath,'-OutputRoot',$outputRoot,'-LogPath',$logPath,'-StrategyOverride','gs-downsample-150','-StatusJson')
            $lines = @(& $pwsh @args 2>&1)
            $rc = $LASTEXITCODE
            $rc | Should -BeIn @(0,6)
            ($lines -join "`n") | Should -Match '##STATUS##'
            (Test-Path -LiteralPath $logPath -PathType Leaf) | Should -BeTrue
            $records = @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $records.Count | Should -BeGreaterThan 0
            $records[0].PSObject.Properties.Name | Should -Contain 'verification_status'
            $formalOutputs = @(Get-ChildItem -LiteralPath $outputRoot -Filter '*.compressed.pdf' -File -ErrorAction SilentlyContinue)
            foreach ($output in $formalOutputs) {
                $check = @(& $toolPaths.qpdf '--check' '--' $output.FullName 2>&1)
                $LASTEXITCODE | Should -BeIn @(0,3)
            }
        } finally {
            if (Test-Path -LiteralPath $evidenceRoot) { Remove-Item -LiteralPath $evidenceRoot -Recurse -Force }
        }
    }
}
