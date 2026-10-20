BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $validator = Join-Path $projectRoot 'installer\Test-PayloadManifest.ps1'
    $digest = ('A' * 64)
    $source = [ordered]@{ archive = 'source.zip'; sha256 = $digest; length = 1 }
    $build = [ordered]@{
        buildId = 'pdfc-test-runtime-001'
        sourceDigest = $digest
        dependencyDigest = $digest
        sdkVersion = '10.0.100'
        createdAt = '2026-08-15T00:00:00+09:00'
        determinismMode = 'tree-digest-canonical'
        correspondingSource = $source
    }
    function Get-TestTreeDigest([object[]]$Files) {
        $lines = @($Files | ForEach-Object {
            '{0}|{1}|{2}' -f ([string]$_.path).Replace('\', '/'), ([string]$_.sha256).ToUpperInvariant(), ([long]$_.length)
        })
        $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '') } finally { $sha.Dispose() }
    }
    function New-TestPayload([string]$Architecture, [string]$Archive, [string]$BuildId) {
        $localBuild = [ordered]@{
            buildId = $BuildId
            sourceDigest = $build.sourceDigest
            dependencyDigest = $build.dependencyDigest
            sdkVersion = $build.sdkVersion
            createdAt = $build.createdAt
            determinismMode = $build.determinismMode
            correspondingSource = $build.correspondingSource
        }
        $files = @([ordered]@{ path = 'README.md'; sha256 = $digest; length = 1 })
        return [ordered]@{
            architecture = $Architecture
            archive = $Archive
            sha256 = $digest
            length = 1
            treeDigest = Get-TestTreeDigest $files
            toolVersions = [ordered]@{ powershell = '7.6.3'; qpdf = '12.3.2'; poppler = '26.07.0'; ghostscript = '10.07.1' }
            files = $files
            build = $localBuild
        }
    }
    function Write-TestManifest([object]$Manifest) {
        $path = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($path, (($Manifest | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
        return $path
    }
}

Describe 'payload manifest v3 structural validator' {
    It 'accepts both runtime entries with independent build provenance' {
        $manifest = [ordered]@{
            schemaVersion = 3
            productId = 'pdf-compressor'
            productVersion = '1.1.0'
            releaseId = 'pdfc-release-test'
            payloads = [ordered]@{
                'win-x64' = New-TestPayload 'x64' 'pdf-compressor-win-x64.zip' 'pdfc-x64-001'
                'win-arm64' = New-TestPayload 'arm64' 'pdf-compressor-win-arm64.zip' 'pdfc-arm64-001'
            }
        }
        $path = Write-TestManifest $manifest
        (& $validator -ManifestPath $path -Runtime win-x64).Valid | Should -BeTrue
        (& $validator -ManifestPath $path -Runtime win-arm64).BuildId | Should -Be 'pdfc-arm64-001'
    }

    It 'fails closed when runtime and architecture disagree' {
        $payload = New-TestPayload 'x64' 'pdf-compressor-win-arm64.zip' 'pdfc-arm64-002'
        $manifest = [ordered]@{
            schemaVersion = 3
            productId = 'pdf-compressor'
            productVersion = '1.1.0'
            releaseId = 'pdfc-release-test'
            payloads = [ordered]@{ 'win-arm64' = $payload }
        }
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-arm64 } | Should -Throw '*Runtime and architecture do not match*'
    }

    It 'rejects unsafe file paths and unknown properties' {
        $payload = New-TestPayload 'x64' 'pdf-compressor-win-x64.zip' 'pdfc-x64-003'
        $payload.files[0].path = '../escape'
        $payload.unexpected = 'reject'
        $manifest = [ordered]@{
            schemaVersion = 3
            productId = 'pdf-compressor'
            productVersion = '1.1.0'
            releaseId = 'pdfc-release-test'
            payloads = [ordered]@{ 'win-x64' = $payload }
        }
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*Unknown payloads.win-x64 property*'
    }

    It 'rejects a file inventory whose signed order does not match treeDigest' {
        $payload = New-TestPayload 'arm64' 'pdf-compressor-win-arm64.zip' 'pdfc-arm64-004'
        $payload.files += [ordered]@{ path = 'SECOND.txt'; sha256 = $digest; length = 2 }
        $manifest = [ordered]@{
            schemaVersion = 3
            productId = 'pdf-compressor'
            productVersion = '1.1.0'
            releaseId = 'pdfc-release-test'
            payloads = [ordered]@{ 'win-arm64' = $payload }
        }
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-arm64 } | Should -Throw '*Payload tree digest mismatch*'
    }

    It 'rejects tool versions that do not match the selected runtime ledger' {
        $payload = New-TestPayload 'arm64' 'pdf-compressor-win-arm64.zip' 'pdfc-arm64-005'
        $payload.toolVersions.qpdf = 'qpdf version 99.0.0'
        $manifest = [ordered]@{
            schemaVersion = 3
            productId = 'pdf-compressor'
            productVersion = '1.1.0'
            releaseId = 'pdfc-release-test'
            payloads = [ordered]@{ 'win-arm64' = $payload }
        }
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-arm64 } | Should -Throw '*Tool version does not match dependency ledger*'
    }
}

Describe 'payload manifest validator fail-closed branches' {
    BeforeAll {
        function New-TestV3Manifest {
            return [ordered]@{
                schemaVersion = 3
                productId = 'pdf-compressor'
                productVersion = '1.1.0'
                releaseId = 'pdfc-release-test'
                payloads = [ordered]@{ 'win-x64' = New-TestPayload 'x64' 'pdf-compressor-win-x64.zip' 'pdfc-x64-branch' }
            }
        }
        function New-TestV1Manifest {
            return [ordered]@{
                schemaVersion = 1
                productId = 'pdf-compressor'
                payloads = [ordered]@{
                    'win-x64' = [ordered]@{
                        archive = 'pdf-compressor-win-x64.zip'
                        sha256 = $digest
                        length = 1
                        files = @([ordered]@{ path = 'README.md'; sha256 = $digest; length = 1 })
                    }
                }
            }
        }
    }

    It 'accepts a minimal schema v1 manifest without build provenance' {
        $result = & $validator -ManifestPath (Write-TestManifest (New-TestV1Manifest)) -Runtime win-x64
        $result.Valid | Should -BeTrue
        $result.SchemaVersion | Should -Be 1
    }

    It 'rejects a missing manifest file' {
        { & $validator -ManifestPath (Join-Path $TestDrive 'missing-manifest.json') -Runtime win-x64 } | Should -Throw '*Manifest is missing*'
    }

    It 'rejects an unsupported schema or product identity' {
        $manifest = New-TestV1Manifest
        $manifest.productId = 'other-product'
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*Unsupported or invalid payload manifest*'
    }

    It 'rejects a manifest whose payloads are null' {
        $manifest = New-TestV1Manifest
        $manifest.payloads = $null
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*Manifest payloads are missing*'
    }

    It 'rejects a manifest that advertises no payload' {
        $manifest = New-TestV1Manifest
        $manifest.payloads = [ordered]@{}
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*does not advertise any payload*'
    }

    It 'rejects a runtime that the manifest does not contain' {
        { & $validator -ManifestPath (Write-TestManifest (New-TestV1Manifest)) -Runtime win-arm64 } | Should -Throw '*Runtime is not present in manifest*'
    }

    It 'rejects an empty payload file inventory' {
        $manifest = New-TestV1Manifest
        $manifest.payloads['win-x64'].files = @()
        # An empty JSON array is rejected before Assert-FileInventory runs (mandatory binding).
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw
    }

    It 'rejects case-colliding payload paths' {
        $manifest = New-TestV1Manifest
        $manifest.payloads['win-x64'].files = @(
            [ordered]@{ path = 'README.md'; sha256 = $digest; length = 1 },
            [ordered]@{ path = 'readme.md'; sha256 = $digest; length = 1 }
        )
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*Duplicate or case-colliding payload path*'
    }

    It 'rejects a non-numeric payload file length' {
        $manifest = New-TestV1Manifest
        $manifest.payloads['win-x64'].files = @([ordered]@{ path = 'README.md'; sha256 = $digest; length = 'one' })
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*Payload file length is not numeric*'
    }

    It 'rejects a negative payload file length' {
        $manifest = New-TestV1Manifest
        $manifest.payloads['win-x64'].files = @([ordered]@{ path = 'README.md'; sha256 = $digest; length = -1 })
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*Payload file length is negative*'
    }

    It 'rejects an unsupported payload architecture' {
        $manifest = New-TestV3Manifest
        $manifest.payloads['win-x64'].architecture = 'x86'
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*Unsupported payload architecture*'
    }

    It 'rejects an unsupported per-payload build determinism mode' {
        $manifest = New-TestV3Manifest
        $manifest.payloads['win-x64'].build.determinismMode = 'best-effort'
        { & $validator -ManifestPath (Write-TestManifest $manifest) -Runtime win-x64 } | Should -Throw '*Unsupported determinism mode*'
    }
}
