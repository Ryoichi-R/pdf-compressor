BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}

Describe 'standalone repository boundary contracts' {
    It 'keeps the implementation snapshot self-contained and repository-scoped' {
        $text = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\New-ImplementationSnapshot.ps1') -Raw
        $schema = Get-Content -LiteralPath (Join-Path $projectRoot '_internal\data\implementation-snapshot.schema.json') -Raw | ConvertFrom-Json
        $text | Should -Not -Match 'scripts\\shared\\secret-patterns\.ps1'
        $text | Should -Match '\$repositoryRoot'
        $text | Should -Not -Match 'Join-Path \$projectRoot ''\.\.\\\.\.'''
        $schema.properties.workspacePolicy.const | Should -Be 'standalone-repository-filesystem-only'
        $schema.properties.projectRoot.const | Should -Be 'project'
    }

    It 'guards every ARM64 dependency build output at the standalone repository root' {
        foreach ($name in @('Build-GhostscriptArm64.ps1', 'Build-PopplerArm64.ps1', 'Build-QpdfArm64.ps1')) {
            $text = Get-Content -LiteralPath (Join-Path $projectRoot "installer\dependencies\$name") -Raw
            $text | Should -Match 'Assert-RepositoryWriteTarget'
            $text | Should -Match 'Join-Path \$projectRoot ''\.\.'''
            $text | Should -Not -Match 'Join-Path \$projectRoot ''\.\.\\\.\.'''
        }
    }

    It 'does not retain public references to the private workspace or its history' {
        $historicalDocs = (Get-ChildItem -LiteralPath (Join-Path $projectRoot 'docs') -File -Filter '*.md' |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $architecture = Get-Content -LiteralPath (Join-Path $projectRoot '_internal\ARCHITECTURE.md') -Raw
        $historicalDocs | Should -Not -Match '(?i)\b[A-Z]:\\'
        $historicalDocs | Should -Not -Match 'Git HEAD at test start:\s*`?[0-9a-f]{40}'
        $architecture | Should -Not -Match '\.\./\.\./(?:TODO\.md|plans/)'
    }

    It 'does not write a machine name into the ARM64 benefit receipt' {
        $text = Get-Content -LiteralPath (Join-Path $projectRoot 'tests\performance\Measure-Arm64NativeBenefit.ps1') -Raw
        $text | Should -Not -Match '\$env:COMPUTERNAME'
        $text | Should -Not -Match 'computerName\s*='
    }

    It 'resolves every legacy project root guard to the standalone repository' {
        $guardedScripts = @(
            Get-ChildItem -LiteralPath (Join-Path $projectRoot 'tests\integration') -File -Filter '*.ps1'
            Get-ChildItem -LiteralPath (Join-Path $projectRoot 'tests\performance') -File -Filter '*.ps1'
        )
        foreach ($script in $guardedScripts) {
            $text = Get-Content -LiteralPath $script.FullName -Raw
            $text | Should -Not -Match 'Join-Path \$projectRoot ''\.\.\\\.\.'''
        }
    }
}
