BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $packageRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..'))
}

Describe 'one-click installer structure' {
    It 'keeps exactly four user-facing root entries' {
        # 独立した公開repositoryのrootとして、入口BAT・README・LICENSE・projectの
        # 4つに固定する。
        $actual = @((Get-ChildItem -LiteralPath $packageRoot -Force).Name |
            Where-Object { -not $_.StartsWith('.') } | Sort-Object)
        $expected = @('LICENSE', 'project', 'README.md', 'ここから開始 - PDF Compressorを導入・更新.bat') |
            Sort-Object
        $actual | Should -Be $expected
    }

    It 'limits hidden root entries to known developer metadata' {
        # SECURITY.md / CONTRIBUTING.md は GitHub が .github/ でも認識するため、
        # 利用者向けフォルダーを汚さずに置ける。増える場合はここへ明示追加する。
        $hidden = @((Get-ChildItem -LiteralPath $packageRoot -Force).Name |
            Where-Object { $_.StartsWith('.') })
        foreach ($entry in $hidden) {
            $entry | Should -BeIn @('.git', '.gitattributes', '.github', '.gitignore')
        }
    }

    It 'ships the developer metadata that a public repository needs' {
        @(
            '.github\SECURITY.md',
            '.github\CONTRIBUTING.md'
        ) | ForEach-Object {
            Join-Path $packageRoot $_ | Should -Exist
        }
        Join-Path $projectRoot 'CHANGELOG.md' | Should -Exist
    }

    It 'ships the required installer sources' {
        @(
            'installer\Install-PdfCompressor.ps1',
            'installer\Build-Payload.ps1',
            'installer\Build-PayloadCandidate.ps1',
            'installer\Compose-PayloadReleaseCandidate.ps1',
            'installer\New-PayloadEntryBat.ps1',
            'installer\Test-PayloadManifest.ps1',
            'installer\Test-Payload.ps1',
            'installer\payload-manifest.schema.json',
            'installer\portable-dependencies.json',
            'src\PdfCompressor.Launcher\PdfCompressor.Launcher.csproj',
            '_internal\installed-cli.ps1',
            'LICENSE',
            'THIRD-PARTY-NOTICES.md'
        ) | ForEach-Object {
            Join-Path $projectRoot $_ | Should -Exist
        }
    }

    It 'uses ASCII CRLF for BAT and UTF-8 no-BOM LF for root README' {
        $bat = [IO.File]::ReadAllBytes((Join-Path $packageRoot 'ここから開始 - PDF Compressorを導入・更新.bat'))
        @($bat | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        [Text.Encoding]::ASCII.GetString($bat) | Should -Not -Match '(?<!\r)\n'

        $readme = [IO.File]::ReadAllBytes((Join-Path $packageRoot 'README.md'))
        @($readme[0..2]) | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        [Text.Encoding]::UTF8.GetString($readme) | Should -Not -Match "`r"
    }

    It 'contains no active legacy specs' {
        @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter '*_spec.ps1').Count |
            Should -Be 0
    }
}

Describe 'root README contract' {
    BeforeAll {
        $script:rootReadmePath = Join-Path $packageRoot 'README.md'
        $script:templateReadmePath = Join-Path $projectRoot 'installer\assets\root-README.md'
    }

    It 'keeps the shipped root README byte-identical to the packaged template' {
        # The template silently drifted from the shipped README until 2026-09-04:
        # the NotSigned/SmartScreen disclosure was missing because, unlike the root
        # entry BAT, no contract bound the two files together.
        $rootBytes = [IO.File]::ReadAllBytes($script:rootReadmePath)
        $templateBytes = [IO.File]::ReadAllBytes($script:templateReadmePath)
        [Convert]::ToBase64String($rootBytes) | Should -Be ([Convert]::ToBase64String($templateBytes))
    }

    It 'discloses the unsigned status and the SHA-256 integrity check' {
        $text = Get-Content -LiteralPath $script:rootReadmePath -Raw
        $text | Should -Match 'NotSigned'
        $text | Should -Match 'SmartScreen'
        $text | Should -Match 'SHA-256'
    }

    It 'states the copyright holder and the MIT license' {
        $text = Get-Content -LiteralPath $script:rootReadmePath -Raw
        $text | Should -Match 'Copyright \(c\) 2026 Ryoichi-Rice and contributors'
        $text | Should -Match 'MIT License'
    }
}

Describe 'root entry BAT contract' {
    BeforeAll {
        $script:rootBatPath = Join-Path $packageRoot 'ここから開始 - PDF Compressorを導入・更新.bat'
        $script:templateBatPath = Join-Path $projectRoot 'installer\assets\root-entry.bat'
        $script:rootBatText = Get-Content -LiteralPath $script:rootBatPath -Raw
    }

    It 'keeps the shipped root BAT byte-identical to the packaged template' {
        $rootBytes = [IO.File]::ReadAllBytes($script:rootBatPath)
        $templateBytes = [IO.File]::ReadAllBytes($script:templateBatPath)
        [Convert]::ToBase64String($rootBytes) | Should -Be ([Convert]::ToBase64String($templateBytes))
    }

    It 'keeps the x64-only profile template byte-identical to the shipped root BAT' {
        $profileBytes = [IO.File]::ReadAllBytes((Join-Path $projectRoot 'installer\assets\root-entry-x64-only.bat'))
        $rootBytes = [IO.File]::ReadAllBytes($script:rootBatPath)
        [Convert]::ToBase64String($profileBytes) | Should -Be ([Convert]::ToBase64String($rootBytes))
    }

    It 'ships a dual-runtime profile that selects native ARM64 explicitly' {
        $dualText = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\assets\root-entry-dual-runtime.bat') -Raw
        $dualText | Should -Match '"%NATIVE_ARCH%"=="ARM64"[\s\S]{0,300}?set "PDF_COMPRESSOR_RUNTIME=win-arm64"'
        $dualText | Should -Match 'set "PSModulePath="'
        $dualText | Should -Match '-AllowRuntimeSwitch'
    }

    It 'ships an arm64-only profile that rejects AMD64 and selects native ARM64' {
        $arm64Text = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\assets\root-entry-arm64-only.bat') -Raw
        $arm64Text | Should -Match '"%NATIVE_ARCH%"=="ARM64"[\s\S]{0,300}?set "PDF_COMPRESSOR_RUNTIME=win-arm64"'
        $arm64Text | Should -Match '"%NATIVE_ARCH%"=="AMD64"[\s\S]{0,300}?contains only the native ARM64 payload'
        $arm64Text | Should -Match 'set "PSModulePath="'
        $arm64Text | Should -Match '-AllowRuntimeSwitch'
    }

    It 'captures the runtime-switch result after choice in every package profile' {
        foreach ($profile in @('root-entry.bat', 'root-entry-x64-only.bat', 'root-entry-arm64-only.bat', 'root-entry-dual-runtime.bat')) {
            $entry = Get-Content -LiteralPath (Join-Path $projectRoot "installer\assets\$profile") -Raw
            $switchCapture = [regex]::Match($entry, '(?s)-AllowRuntimeSwitch\s*\r?\n(?<capture>[^\r\n]+)')
            $switchCapture.Success | Should -BeTrue
            $switchCapture.Groups['capture'].Value.Trim() | Should -Be 'call set "RC=%%ERRORLEVEL%%"'
        }
    }

    It 'installs the verified win-x64 payload on ARM64 hosts under x64 emulation' {
        # No native ARM64 payload exists. Selecting win-arm64 here would fail the
        # installer's runtime-token check and leave ARM64 users with no install path.
        $script:rootBatText | Should -Match '"%NATIVE_ARCH%"=="ARM64"[\s\S]{0,400}?set "PDF_COMPRESSOR_RUNTIME=win-x64"'
        $script:rootBatText | Should -Not -Match 'PDF_COMPRESSOR_RUNTIME=win-arm64'
    }

    It 'clears an inherited PSModulePath before starting Windows PowerShell' {
        # A PowerShell 7 parent process leaks its PSModulePath into powershell.exe,
        # which then cannot resolve Get-FileHash and fails payload verification.
        $clearIndex = $script:rootBatText.IndexOf('set "PSModulePath="')
        $invokeIndex = $script:rootBatText.IndexOf('powershell.exe -STA')
        $clearIndex | Should -BeGreaterThan 0
        $invokeIndex | Should -BeGreaterThan $clearIndex
    }

    It 'does not authorize win-arm64 unless the manifest validator finds that runtime' {
        $installerText = Get-Content -LiteralPath (
            Join-Path $projectRoot 'installer\Install-PdfCompressor.ps1'
        ) -Raw
        $installerText | Should -Match 'Test-Payload\.ps1'
        $installerText | Should -Match 'ExitRuntimeSwitchRequired'
        $installerText | Should -Not -Match "win-arm64 payload is not supported"
    }
}

Describe 'launcher window contract' {
    It 'uses a Windows GUI subsystem and starts bundled PowerShell without a console window' {
        $projectText = Get-Content -LiteralPath (Join-Path $projectRoot 'src\PdfCompressor.Launcher\PdfCompressor.Launcher.csproj') -Raw
        $programText = Get-Content -LiteralPath (Join-Path $projectRoot 'src\PdfCompressor.Launcher\Program.cs') -Raw
        $projectText | Should -Match '<OutputType>WinExe</OutputType>'
        $programText | Should -Match 'CreateNoWindow\s*=\s*true'
        $programText | Should -Not -Match 'WindowStyle\s*=\s*ProcessWindowStyle\.Hidden'
    }

    It 'does not block headless diagnostics failures on a GUI error dialog' {
        $programText = Get-Content -LiteralPath (Join-Path $projectRoot 'src\PdfCompressor.Launcher\Program.cs') -Raw
        $programText | Should -Match 'catch \(Exception ex\)[\s\S]{0,200}?if \(diagnosticsMode\)[\s\S]{0,200}?Console\.Error\.WriteLine\(ex\);[\s\S]{0,100}?return 1;'
        $programText | Should -Match 'ShowError\('
    }

    It 'selects the launcher RID at build time instead of pinning win-x64 in the project' {
        $projectText = Get-Content -LiteralPath (Join-Path $projectRoot 'src\PdfCompressor.Launcher\PdfCompressor.Launcher.csproj') -Raw
        $builderText = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-PayloadCandidate.ps1') -Raw
        $projectText | Should -Not -Match '<RuntimeIdentifier>win-x64</RuntimeIdentifier>'
        $builderText | Should -Match 'dotnet restore[\s\S]{0,300}-r \$Runtime'
        $builderText | Should -Match 'dotnet publish[\s\S]{0,300}-r \$Runtime'
        $builderText | Should -Match 'Get-BuildId[\s\S]{0,300}-SelectedRuntime \$Runtime[\s\S]{0,300}-DependencyDigest \$dependencyDigest'
        $builderText | Should -Match 'hostArchitecture'
        $builderText | Should -Match 'launcherSha256'
    }

    It 'shows the GUI before restoring the previous input' {
        $guiText = Get-Content -LiteralPath (Join-Path $projectRoot '_internal\gui.ps1') -Raw
        $shownIndex = $guiText.IndexOf('$form.Add_Shown')
        $restoreIndex = $guiText.IndexOf('Add-GuiInputPaths -Paths ($script:Settings.lastInput')
        $dialogIndex = $guiText.LastIndexOf('[void]$form.ShowDialog()')
        $shownIndex | Should -BeGreaterThan 0
        $restoreIndex | Should -BeGreaterThan $shownIndex
        $dialogIndex | Should -BeGreaterThan $restoreIndex
        $guiText | Should -Match '\$form\.BeginInvoke\(\[Action\]'
        $startupBlock = $guiText.Substring($shownIndex, $dialogIndex - $shownIndex)
        $startupBlock | Should -Match 'Update-OutputValidationStyle'
        $startupBlock | Should -Match 'Update-GuiQueueView'
        $startupBlock | Should -Match 'Update-RunGate'
    }
}

Describe 'payload manifest' {
    BeforeAll {
        # installer/payload/ は .gitignore 対象のローカルビルド成果物であり、
        # fresh clone や部分チェックアウトには存在しない。不在時は検証をスキップする。
        $script:PayloadManifestPath = Join-Path $projectRoot 'installer/payload/payload-manifest.json'
        $script:PayloadPresent = Test-Path -LiteralPath $script:PayloadManifestPath
        # release 検証では payload 不在の Skip を fail-closed にする。CI の release job と
        # 公開前監査は PDF_COMPRESSOR_REQUIRE_PAYLOAD=1 を設定してこの gate を必須にする。
        $script:PayloadRequired = $env:PDF_COMPRESSOR_REQUIRE_PAYLOAD -eq '1'
    }
    # Windows PowerShell 5.1 (powershell.exe) を起動して互換性を検証するため Windows 専用。
    It 'keeps payload verification compatible with Windows PowerShell 5.1' -Tag 'WindowsOnly' {
        if (-not $script:PayloadPresent) {
            if ($script:PayloadRequired) {
                throw 'PDF_COMPRESSOR_REQUIRE_PAYLOAD=1 が設定されているが installer/payload/payload-manifest.json が存在しない。'
            }
            Set-ItResult -Skipped -Because 'installer/payload/payload-manifest.json が存在しない（.gitignore 対象のローカルビルド成果物）'
            return
        }
        $validator = Join-Path $projectRoot 'installer\Test-Payload.ps1'
        $validatorText = Get-Content -LiteralPath $validator -Raw
        $validatorText | Should -Not -Match 'SHA256\]::HashData|Convert\]::ToHexString'
        $validatorText | Should -Not -Match '\$Files\s*\|\s*Sort-Object'
        $validatorText | Should -Match '(?ms)\$diagnosticRoot\s*=\s*Join-Path\s+\$dest\s+''_work''[\s\S]*Directory\]::CreateDirectory\(\$diagnosticRoot\)'

        $manifestPath = Join-Path $projectRoot 'installer\payload\payload-manifest.json'
        $command = "& '$($validator.Replace("'", "''"))' -ManifestPath '$($manifestPath.Replace("'", "''"))' -Runtime win-x64 | ConvertTo-Json -Compress"
        $resultJson = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -NoProfile -ExecutionPolicy Bypass -Command $command
        $LASTEXITCODE | Should -Be 0
        ($resultJson | ConvertFrom-Json).Valid | Should -BeTrue
    }

    It 'passes archive and recursive manifest validation' {
        if (-not $script:PayloadPresent) {
            if ($script:PayloadRequired) {
                throw 'PDF_COMPRESSOR_REQUIRE_PAYLOAD=1 が設定されているが installer/payload/payload-manifest.json が存在しない。'
            }
            Set-ItResult -Skipped -Because 'installer/payload/payload-manifest.json が存在しない（.gitignore 対象のローカルビルド成果物）'
            return
        }
        $result = & (Join-Path $projectRoot 'installer\Test-Payload.ps1') `
            -ManifestPath (Join-Path $projectRoot 'installer\payload\payload-manifest.json') `
            -Runtime win-x64
        $result.Valid | Should -BeTrue
    }

    It 'does not advertise an unverified ARM64 payload' {
        if (-not $script:PayloadPresent) {
            if ($script:PayloadRequired) {
                throw 'PDF_COMPRESSOR_REQUIRE_PAYLOAD=1 が設定されているが installer/payload/payload-manifest.json が存在しない。'
            }
            Set-ItResult -Skipped -Because 'installer/payload/payload-manifest.json が存在しない（.gitignore 対象のローカルビルド成果物）'
            return
        }
        $manifest = Get-Content -LiteralPath (
            Join-Path $projectRoot 'installer\payload\payload-manifest.json'
        ) -Raw | ConvertFrom-Json
        $manifest.payloads.PSObject.Properties.Name | Should -Not -Contain 'win-arm64'
    }

    It 'accepts the v3 manifest validator as a Windows PowerShell 5.1 script' {
        $validator = Join-Path $projectRoot 'installer\Test-PayloadManifest.ps1'
        $validatorText = Get-Content -LiteralPath $validator -Raw
        $validatorText | Should -Not -Match 'SHA256\]::HashData|Convert\]::ToHexString'
        $validatorText | Should -Not -Match 'Get-FileHash|Expand-Archive'
    }
}

Describe 'candidate source inventory' {
    It 'excludes build outputs and verifies source stability before writing the receipt' {
        $builder = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-PayloadCandidate.ps1') -Raw
        $builder | Should -Match "Replace\('\\', '/'\)\s+-notmatch\s+'\(\^\|/\)\(bin\|obj\)\(/\|\$\)'"
        $builder | Should -Match 'finalSourceDigest\s*=\s*Get-CanonicalDigest\s*\(Get-SourceInventory\)'
        $builder | Should -Match 'Source inventory changed during candidate build'
    }

    It 'includes ARM64 source-build recipes in the corresponding-source archive' {
        $builder = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-PayloadCandidate.ps1') -Raw
        $builder | Should -Match '\$Runtime -eq ''win-arm64'''
        foreach ($recipe in @('Build-QpdfArm64.ps1', 'Build-PopplerArm64.ps1', 'Build-GhostscriptArm64.ps1', 'poppler-vcpkg.json')) {
            $builder | Should -Match ([regex]::Escape($recipe))
        }
    }

    It 'includes x64 source-build recipes in the corresponding-source archive' {
        # AGPLv3 counts the scripts that control compilation and installation as
        # Corresponding Source. Emitting recipes only for win-arm64 left the canonical
        # win-x64 sidecar short of that requirement.
        $builder = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-PayloadCandidate.ps1') -Raw
        $builder | Should -Match 'buildRecipes'
        $builder | Should -Match "(?s)\} else \{\s*@\(\s*'Build-Poppler\.ps1',\s*'poppler-vcpkg\.json',\s*'Test-PopplerSourceSignature\.ps1'\s*\)"
    }

    It 'binds product and installer source into new corresponding-source archives' {
        $builder = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-PayloadCandidate.ps1') -Raw
        $builder | Should -Match ([regex]::Escape("foreach (`$relativeRoot in @('_internal', 'src', 'installer', 'licenses'))"))
        $builder | Should -Match "installer/\(candidates\|payload\|_work\|dependency-evidence\)"
        $builder | Should -Match "product-source"
        $builder | Should -Match "Product corresponding-source hash mismatch"
    }

    It 'emits new single-runtime candidates as schema v3' {
        $builder = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-PayloadCandidate.ps1') -Raw
        $builder | Should -Match 'schemaVersion\s*=\s*3'
        $builder | Should -Match 'releaseId\s*=\s*Get-SingleRuntimeReleaseId'
        $builder | Should -Match 'build\s*=\s*\[ordered\]'
        $builder | Should -Match 'manifestSchemaVersion\s*=\s*3'
    }

    It 'keeps the launcher informational version identical to the manifest build id' {
        $builder = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-PayloadCandidate.ps1') -Raw
        $builder | Should -Match 'InformationalVersion=\$buildId'
        $builder | Should -Match 'IncludeSourceRevisionInInformationalVersion=false'
    }

    It 'binds the runtime-specific package profile into the candidate receipt' {
        $builder = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-PayloadCandidate.ps1') -Raw
        $builder | Should -Match '\$Runtime -eq ''win-arm64''[\s\S]{0,100}?''arm64-only'''
        $builder | Should -Match '\$Runtime -eq ''win-arm64''[\s\S]{0,100}?''x64-only'''
        $builder | Should -Match 'profileEntrySha256\s*=\s*\$profileResult\.Sha256'
        $builder | Should -Match 'profileEntryLength'
    }
}

Describe 'installed tool resolution' {
    It 'uses only the bundled tree in installed mode' {
        . (Join-Path $projectRoot '_internal\tool-resolver.ps1')
        $oldRoot = $env:PDF_COMPRESSOR_INSTALL_ROOT
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdf-resolver-' + [Guid]::NewGuid())
        try {
            [IO.Directory]::CreateDirectory((Join-Path $tempRoot 'runtime\tools')) | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $tempRoot 'runtime\tools\qpdf.exe'), [byte[]](1))
            $env:PDF_COMPRESSOR_INSTALL_ROOT = $tempRoot
            Find-ToolExecutable qpdf | Should -Be (Join-Path $tempRoot 'runtime\tools\qpdf.exe')
            Find-ToolExecutable definitelyMissing | Should -BeNullOrEmpty
        } finally {
            $env:PDF_COMPRESSOR_INSTALL_ROOT = $oldRoot
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'dependency acquisition' {
    BeforeAll {
        $script:Fetcher = Join-Path $projectRoot 'installer\dependencies\Get-PortableDependencies.ps1'
        $script:Sources = Join-Path $projectRoot 'installer\dependencies\download-sources.json'
    }

    It 'ships the fetcher and its download source list' {
        $script:Fetcher | Should -Exist
        $script:Sources | Should -Exist
    }

    It 'resolves an https URL for every downloadable win-x64 artifact' {
        $plan = & $script:Fetcher -Runtime win-x64 -DestinationRoot $TestDrive -WhatIfList
        @($plan).Count | Should -BeGreaterThan 0
        foreach ($item in $plan) {
            $item.Kind | Should -Not -Be 'local-build'
            $item.Url | Should -Match '^https://'
            $item.Sha256 | Should -Match '^[0-9A-F]{64}$'
        }
    }

    It 'classifies locally built ARM64 artifacts instead of inventing a URL' {
        # win-arm64 の qpdf / Poppler / Ghostscript は固定ソースからのローカルビルドで、
        # 公式配布物が存在しない。URL を捏造せず build recipe へ委ねること。
        $plan = & $script:Fetcher -Runtime win-arm64 -DestinationRoot $TestDrive -WhatIfList
        $localBuilds = @($plan | Where-Object { $_.Kind -eq 'local-build' })
        $localBuilds.Count | Should -BeGreaterThan 0
        foreach ($item in $localBuilds) { $item.Url | Should -BeNullOrEmpty }
    }

    It 'acquires the official Ghostscript Windows binary for win-x64, not only its source' {
        # 失われた payload の 1711 件インベントリに runtime/ghostscript/uninstgs.exe が
        # 含まれていたことから、x64 の Ghostscript は公式 Windows バイナリ由来と確定した
        # (2026-09-04)。台帳が source tarball だけを指していると、再ビルドに必要な
        # 成果物を取得できない。
        $plan = & $script:Fetcher -Runtime win-x64 -DestinationRoot $TestDrive -WhatIfList
        $gs = @($plan | Where-Object { $_.Name -eq 'Ghostscript' })
        $gs.Count | Should -Be 1
        $gs[0].Artifact | Should -Be 'gs10071w64.exe'
        $gs[0].Url | Should -Match '^https://github\.com/ArtifexSoftware/'
    }

    It 'keeps the Ghostscript corresponding source bound next to the binary' {
        # AGPL の対応ソース義務はバイナリを配る側にある。artifact をバイナリへ変えても
        # sourceArtifact / sourceSha256 が残っていないと sidecar が作れない。
        $ledger = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\portable-dependencies.json') -Raw | ConvertFrom-Json
        $gs = @($ledger.runtimes.'win-x64'.dependencies | Where-Object { $_.name -eq 'Ghostscript' })
        $gs.Count | Should -Be 1
        $gs[0].sourceArtifact | Should -Be 'ghostscript-10.07.1.tar.xz'
        $gs[0].sourceSha256 | Should -Match '^[0-9A-F]{64}$'
    }

    It 'keeps SHA-256 out of the download list so the ledger stays the single source of truth' {
        $text = Get-Content -LiteralPath $script:Sources -Raw
        $text | Should -Not -Match '(?i)sha256'
    }

    It 'verifies the hash before the artifact takes its final name' {
        # 照合前のバイト列が正規の名前で残ると、次回実行が already-present と誤認する。
        $text = Get-Content -LiteralPath $script:Fetcher -Raw
        $text | Should -Match ([regex]::Escape('$temp = "$Destination.$([Guid]::NewGuid().ToString(''N'')).part"'))
        $text | Should -Match 'SHA-256 が台帳と一致しません'
        $text | Should -Match ([regex]::Escape('Move-Item -LiteralPath $temp -Destination $Destination'))
    }
}
