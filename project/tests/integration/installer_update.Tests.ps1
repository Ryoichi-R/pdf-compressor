BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $installer = Join-Path $projectRoot 'installer\Install-PdfCompressor.ps1'
    $manifest = Join-Path $projectRoot 'installer\payload\payload-manifest.json'
    $payload = Join-Path $projectRoot 'installer\payload'
    $synthetic = Join-Path $projectRoot 'tests\support\New-SyntheticPdf.ps1'

    function Get-TestInstallStatePaths([string]$Parent) {
        $root = Join-Path $Parent 'PDF Compressor'
        $normalized = [IO.Path]::GetFullPath($root).TrimEnd('\').ToUpperInvariant()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))) -replace '-', '').Substring(0, 24) } finally { $sha.Dispose() }
        $local = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'pdf-compressor'
        [pscustomobject]@{
            installRoot = $root
            stateRoot = Join-Path $local "runtime-state\$hash"
            backupRoot = Join-Path $local "backups\$hash"
        }
    }

    function Remove-OwnedTestDirectory([string]$Path,[string]$AllowedParent) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $parent = [IO.Path]::GetFullPath($AllowedParent).TrimEnd('\')
        if (-not $full.StartsWith($parent + '\',[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup target: $full" }
        $items = @(Get-Item -LiteralPath $full -Force) + @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop)
        if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) { throw "Test cleanup target contains a reparse point: $full" }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }

    function Remove-TestInstallArtifacts([string]$Parent) {
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
        if ((Split-Path -Leaf $parentFull) -notlike 'pdf-compressor-*') { throw "Unexpected test parent: $parentFull" }
        $paths = Get-TestInstallStatePaths $Parent
        $local = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'pdf-compressor'
        Remove-OwnedTestDirectory -Path $paths.stateRoot -AllowedParent (Join-Path $local 'runtime-state')
        Remove-OwnedTestDirectory -Path $paths.backupRoot -AllowedParent (Join-Path $local 'backups')
        Remove-OwnedTestDirectory -Path $parentFull -AllowedParent $temp
    }
}

Describe 'installed package integration' -Tag 'WindowsOnly' {
    It 'installs, compresses a real PDF, and preserves user-owned files on update' {
        $parent = Join-Path ([IO.Path]::GetTempPath()) ('pdf-compressor-integration-' + [Guid]::NewGuid())
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
        try {
            $env:PDF_COMPRESSOR_INSTALL_PARENT = $parent
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen
            $LASTEXITCODE | Should -Be 0
            $root = Join-Path $parent 'PDF Compressor'
            $userFile = Join-Path $root 'user-added.txt'
            Set-Content -Path $userFile -Value 'keep' -Encoding utf8
            $input = Join-Path $parent 'input.pdf'
            . $synthetic
            New-SyntheticPdf -OutputPath $input -PageCount 50 -TargetBytes 10MB | Out-Null
            $cli = Join-Path $root 'compress.bat'
            $output = & $cli $input 2>&1
            $LASTEXITCODE | Should -BeIn @(0, 4, 6)
            @(Get-ChildItem -Path (Join-Path $root 'output') -Recurse -File -Filter '*.pdf' -ErrorAction SilentlyContinue).Count | Should -BeGreaterThan 0

            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $userFile | Should -BeTrue

            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen -ApproveBackupRetentionCleanup
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $userFile | Should -BeTrue
            $paths = Get-TestInstallStatePaths $parent
            @(Get-ChildItem -LiteralPath $paths.backupRoot -Directory -Filter 'previous-*').Count | Should -Be 1
        } finally {
            Remove-Item Env:PDF_COMPRESSOR_INSTALL_PARENT -ErrorAction SilentlyContinue
            Remove-TestInstallArtifacts $parent
        }
    }

    It 'rejects an update while an active lease is held' {
        $parent = Join-Path ([IO.Path]::GetTempPath()) ('pdf-compressor-busy-' + [Guid]::NewGuid())
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
        $env:PDF_COMPRESSOR_INSTALL_PARENT = $parent
        try {
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen
            $root = Join-Path $parent 'PDF Compressor'
            $normalized = [IO.Path]::GetFullPath($root).TrimEnd('\\').ToUpperInvariant()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))) -replace '-', '').Substring(0, 24) } finally { $sha.Dispose() }
            $state = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "pdf-compressor\runtime-state\$hash"
            New-Item -Path $state -ItemType Directory -Force | Out-Null
            $leasePath = Join-Path $state 'lease-integration.lock'
            $lease = [IO.File]::Open($leasePath, 'Create', 'ReadWrite', 'Read')
            try {
                & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen
                $LASTEXITCODE | Should -Be 8
            } finally {
                $lease.Dispose()
                Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Item Env:PDF_COMPRESSOR_INSTALL_PARENT -ErrorAction SilentlyContinue
            Remove-TestInstallArtifacts $parent
        }
    }

    It 'repairs a missing managed file during update' {
        $parent = Join-Path ([IO.Path]::GetTempPath()) ('pdf-compressor-repair-' + [Guid]::NewGuid())
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
        $env:PDF_COMPRESSOR_INSTALL_PARENT = $parent
        try {
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen
            $LASTEXITCODE | Should -Be 0
            $root = Join-Path $parent 'PDF Compressor'
            $missing = Join-Path $root '_internal\analyze_pdf.ps1'
            $markerPath = Join-Path $root '.pdf-compressor-install.json'
            $legacyMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            foreach ($managed in @($legacyMarker.managedFiles)) {
                $managed.path = $managed.path.Replace('/', '\')
            }
            $legacyMarker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $markerPath -Encoding UTF8
            Remove-Item -LiteralPath $missing -Force
            Test-Path -LiteralPath $missing | Should -BeFalse

            $installerText = Get-Content -LiteralPath $installer -Raw
            $installerText | Should -Not -Match 'Test-Path[^\r\n]+managedPath[^\r\n]+Get-Item'

            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $missing -PathType Leaf | Should -BeTrue
            $expected = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).payloads.'win-x64'.files |
                Where-Object { ($_.path -replace '\\', '/') -eq '_internal/analyze_pdf.ps1' }
            $expected | Should -Not -BeNullOrEmpty
            (Get-FileHash -LiteralPath $missing -Algorithm SHA256).Hash | Should -Be $expected.sha256
        } finally {
            Remove-Item Env:PDF_COMPRESSOR_INSTALL_PARENT -ErrorAction SilentlyContinue
            Remove-TestInstallArtifacts $parent
        }
    }

    It 'rolls back all managed files after an injected mid-update failure' {
        $parent = Join-Path ([IO.Path]::GetTempPath()) ('pdf-compressor-rollback-' + [Guid]::NewGuid())
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
        $env:PDF_COMPRESSOR_INSTALL_PARENT = $parent
        try {
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen
            $LASTEXITCODE | Should -Be 0
            $root = Join-Path $parent 'PDF Compressor'
            $marker = Join-Path $root '.pdf-compressor-install.json'
            $before = Get-FileHash -LiteralPath (Join-Path $root 'PdfCompressor.App.exe') -Algorithm SHA256
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -Runtime win-x64 -NoOpen -TestFailAfterFiles 3
            $LASTEXITCODE | Should -Be 1
            (Get-FileHash -LiteralPath (Join-Path $root 'PdfCompressor.App.exe') -Algorithm SHA256).Hash | Should -Be $before.Hash
            Test-Path -LiteralPath $marker | Should -BeTrue
            (Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json).productId | Should -Be 'pdf-compressor'
        } finally {
            Remove-Item Env:PDF_COMPRESSOR_INSTALL_PARENT -ErrorAction SilentlyContinue
            Remove-TestInstallArtifacts $parent
        }
    }
}
