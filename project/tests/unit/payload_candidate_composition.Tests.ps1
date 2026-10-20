BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $installerRoot = Join-Path $projectRoot 'installer'
    $composer = Join-Path $installerRoot 'Compose-PayloadReleaseCandidate.ps1'
    $manifestValidator = Join-Path $installerRoot 'Test-PayloadManifest.ps1'
    $fixtureRoot = Join-Path $installerRoot ('_work\composition-test-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

    function Get-TestDigest([object[]]$Files) {
        $lines = @($Files | ForEach-Object { '{0}|{1}|{2}' -f $_.path, $_.sha256.ToUpperInvariant(), $_.length })
        $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '') } finally { $sha.Dispose() }
    }

    function New-Candidate([string]$Runtime, [string]$Architecture, [string]$BuildId) {
        $root = Join-Path $fixtureRoot ($Runtime + '-' + $BuildId)
        $stage = Join-Path $root 'stage'
        $sourceStage = Join-Path $root 'source-stage'
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        [IO.Directory]::CreateDirectory($sourceStage) | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'README.md'), $Runtime, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sourceStage 'SOURCE.txt'), $Runtime, [Text.UTF8Encoding]::new($false))
        $archive = Join-Path $root "pdf-compressor-$Runtime.zip"
        $sourceArchive = Join-Path $root "pdf-compressor-corresponding-source-$Runtime.zip"
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive
        Compress-Archive -Path (Join-Path $sourceStage '*') -DestinationPath $sourceArchive
        $fileHash = (Get-FileHash -LiteralPath (Join-Path $stage 'README.md') -Algorithm SHA256).Hash
        $files = @([ordered]@{ path = 'README.md'; sha256 = $fileHash; length = [long](Get-Item -LiteralPath (Join-Path $stage 'README.md')).Length })
        $treeDigest = Get-TestDigest $files
        $archiveItem = Get-Item -LiteralPath $archive
        $sourceItem = Get-Item -LiteralPath $sourceArchive
        $digest = ('B' * 64)
        $manifest = [ordered]@{
            schemaVersion = 2
            productId = 'pdf-compressor'
            productVersion = '1.1.0'
            buildId = $BuildId
            sourceDigest = $digest
            dependencyDigest = $digest
            sdkVersion = '10.0.100'
            createdAt = '2026-08-15T00:00:00+09:00'
            determinismMode = 'tree-digest-canonical'
            correspondingSource = [ordered]@{ archive = $sourceItem.Name; sha256 = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash; length = [long]$sourceItem.Length }
            payloads = [ordered]@{
                $Runtime = [ordered]@{
                    architecture = $Architecture
                    archive = $archiveItem.Name
                    sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
                    length = [long]$archiveItem.Length
                    treeDigest = $treeDigest
                    toolVersions = [ordered]@{ powershell = '7.6.3'; qpdf = '12.3.2'; poppler = '26.07.0'; ghostscript = '10.07.1' }
                    files = $files
                }
            }
        }
        [IO.File]::WriteAllText((Join-Path $root 'payload-manifest.json'), (($manifest | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
        return $root
    }
}

AfterAll {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

Describe 'candidate-first runtime composition' {
    It 'composes v3 without modifying either input candidate' {
        $x64 = New-Candidate 'win-x64' 'x64' 'pdfc-x64-test'
        $arm64 = New-Candidate 'win-arm64' 'arm64' 'pdfc-arm64-test'
        $x64ArchiveHash = (Get-FileHash -LiteralPath (Join-Path $x64 'pdf-compressor-win-x64.zip') -Algorithm SHA256).Hash
        $output = Join-Path $fixtureRoot 'output'
        & $composer -X64BaselineRoot $x64 -Arm64CandidateRoot $arm64 -OutputCandidateRoot $output | Out-Null
        $manifestPath = Join-Path $output 'payload-manifest.json'
        (& $manifestValidator -ManifestPath $manifestPath -Runtime win-arm64).BuildId | Should -Be 'pdfc-arm64-test'
        (Get-FileHash -LiteralPath (Join-Path $output 'pdf-compressor-win-x64.zip') -Algorithm SHA256).Hash | Should -Be $x64ArchiveHash
        Test-Path -LiteralPath (Join-Path $output 'profiles\dual-runtime\root-entry.bat') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $output 'profiles\arm64-only\root-entry.bat') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $output 'release-composition-receipt.json') | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $x64 'pdf-compressor-win-x64.zip') -Algorithm SHA256).Hash | Should -Be $x64ArchiveHash
    }

    It 'fails closed and removes output when an input archive was modified' {
        $x64 = New-Candidate 'win-x64' 'x64' 'pdfc-x64-tampered'
        $arm64 = New-Candidate 'win-arm64' 'arm64' 'pdfc-arm64-tampered'
        $output = Join-Path $fixtureRoot 'tampered-output'
        Add-Content -LiteralPath (Join-Path $arm64 'pdf-compressor-win-arm64.zip') -Value 'tampered'

        { & $composer -X64BaselineRoot $x64 -Arm64CandidateRoot $arm64 -OutputCandidateRoot $output } |
            Should -Throw '*Payload archive does not match its manifest*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'fails closed and removes output when the file inventory digest was changed' {
        $x64 = New-Candidate 'win-x64' 'x64' 'pdfc-x64-tree'
        $arm64 = New-Candidate 'win-arm64' 'arm64' 'pdfc-arm64-tree'
        $manifestPath = Join-Path $arm64 'payload-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.payloads.'win-arm64'.files[0].length = 999
        [IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
        $output = Join-Path $fixtureRoot 'tree-output'

        { & $composer -X64BaselineRoot $x64 -Arm64CandidateRoot $arm64 -OutputCandidateRoot $output } |
            Should -Throw '*Payload tree digest mismatch*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }
}
