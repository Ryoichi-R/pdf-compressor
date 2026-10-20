BeforeAll {
    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $harnessPath = Join-Path $projectRoot 'tests\performance\Measure-Arm64NativeBenefit.ps1'
    $schemaPath = Join-Path $projectRoot 'tests\performance\arm64-native-benefit.schema.json'

    # Builds a throwaway install root whose bundled pwsh is a junction to the host
    # PowerShell directory, plus a stub compress.ps1 that floods stdout and records
    # the environment it was launched with. Lets the harness run end to end without
    # the real 233 MB payload.
    function New-HarnessSandbox([int]$StubExitCode = 0) {
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('arm64-benefit-sandbox-' + [Guid]::NewGuid().ToString('N'))
        $installRoot = Join-Path $sandbox 'install-root'
        $internalDir = Join-Path $installRoot '_internal'
        $junction = Join-Path $installRoot 'runtime\pwsh'
        New-Item -ItemType Directory -Path $internalDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $installRoot 'runtime') -Force | Out-Null
        $hostPwshDir = Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        New-Item -ItemType Junction -Path $junction -Target $hostPwshDir | Out-Null

        $stub = @'
param([string]$InputPath, [string]$OutputRoot, [string]$StrategyOverride, [switch]$Force, [switch]$StatusJson)
$line = 'x' * 200
for ($i = 0; $i -lt 2000; $i++) { Write-Output $line }
[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $OutputRoot 'out.pdf'), '%PDF-1.4')
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $InputPath) 'install-root.txt'), [string]$env:PDF_COMPRESSOR_INSTALL_ROOT)
exit __STUB_EXIT__
'@
        $stub = $stub.Replace('__STUB_EXIT__', [string]$StubExitCode)
        Set-Content -LiteralPath (Join-Path $internalDir 'compress.ps1') -Value $stub -Encoding utf8

        $corpus = Join-Path $sandbox 'corpus'
        New-Item -ItemType Directory -Path $corpus -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $corpus 'input.pdf') -Value '%PDF-1.4' -Encoding ascii

        return [pscustomobject]@{
            Root = $sandbox
            InstallRoot = $installRoot
            Junction = $junction
            Corpus = $corpus
            ReceiptPath = Join-Path $sandbox 'receipt.json'
        }
    }

    function Remove-HarnessSandbox([object]$Sandbox) {
        # Delete the reparse point itself first so the junction target (the host
        # PowerShell installation) is never reached by the recursive removal.
        if (Test-Path -LiteralPath $Sandbox.Junction) { [IO.Directory]::Delete($Sandbox.Junction, $false) }
        if (Test-Path -LiteralPath $Sandbox.Root) { Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    function Invoke-HarnessRun([object]$Sandbox, [string]$Harness, [int]$TimeoutSeconds = 120) {
        $job = Start-Job -ScriptBlock {
            param($HarnessPath, $Corpus, $InstallRoot, $Receipt)
            & $HarnessPath -Runtime win-x64 -CorpusPath $Corpus -InstallRoot $InstallRoot -OutputPath $Receipt -WarmupCount 0 -TrialCount 1 | Out-Null
        } -ArgumentList $Harness, $Sandbox.Corpus, $Sandbox.InstallRoot, $Sandbox.ReceiptPath
        try {
            $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
            if ($completed) { Receive-Job -Job $job -ErrorAction Stop | Out-Null }
            return [bool]$completed
        } finally {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'ARM64 native benefit measurement contract' {
    It 'defines a schema with warmup, trial, corpus, and threshold fields' {
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        @($schema.required) | Should -Contain 'warmupCount'
        @($schema.required) | Should -Contain 'trialCount'
        @($schema.required) | Should -Contain 'corpus'
        @($schema.required) | Should -Contain 'thresholdEvaluation'
    }

    It 'uses bundled runtime paths and keeps threshold evaluation unevaluated without approval' {
        $text = Get-Content -LiteralPath $harnessPath -Raw
        $text | Should -Match 'runtime\\pwsh\\pwsh\.exe'
        $text | Should -Match 'WarmupCount'
        $text | Should -Match 'TrialCount'
        $text | Should -Match "status = 'not-evaluated'"
        $text | Should -Match 'Owner-approved threshold was not supplied'
    }

    It 'completes a trial when the compression child writes more than the pipe buffer' -Tag 'WindowsOnly' {
        # Regression: reading the redirected pipes only after the child exits deadlocks
        # as soon as the child writes more than the pipe buffer (~4 KB) holds.
        $sandbox = New-HarnessSandbox
        try {
            $completed = Invoke-HarnessRun -Sandbox $sandbox -Harness $harnessPath
            $completed | Should -BeTrue -Because 'the harness must not block on a full stdout pipe'

            $receipt = Get-Content -LiteralPath $sandbox.ReceiptPath -Raw | ConvertFrom-Json
            $receipt.status | Should -Be 'measured'
            @($receipt.trials).Count | Should -Be 1
            @($receipt.trials)[0].exitCode | Should -Be 0
        } finally {
            Remove-HarnessSandbox $sandbox
        }
    }

    It 'exports PDF_COMPRESSOR_INSTALL_ROOT so the child resolves bundled tools only' -Tag 'WindowsOnly' {
        # Regression: without this variable the tool resolver falls back to host PATH
        # installations, so the receipt would describe host tools, not the payload.
        $sandbox = New-HarnessSandbox
        try {
            $completed = Invoke-HarnessRun -Sandbox $sandbox -Harness $harnessPath
            $completed | Should -BeTrue

            $recorded = Get-ChildItem -LiteralPath $sandbox.Root -Recurse -File -Filter 'install-root.txt' |
                Select-Object -First 1
            $recorded | Should -Not -BeNullOrEmpty -Because 'the stub child must have run'
            (Get-Content -LiteralPath $recorded.FullName -Raw).Trim() |
                Should -Be ([IO.Path]::GetFullPath($sandbox.InstallRoot))
        } finally {
            Remove-HarnessSandbox $sandbox
        }
    }

    It 'measures a trial that exits 6 because a safety skip needs operator action' -Tag 'WindowsOnly' {
        # Regression: exit 6 is the documented "operator action required" code, not an
        # error. Treating any non-zero exit as a failed trial makes every corpus that
        # contains a signed PDF unmeasurable.
        $sandbox = New-HarnessSandbox -StubExitCode 6
        try {
            Invoke-HarnessRun -Sandbox $sandbox -Harness $harnessPath | Should -BeTrue

            $receipt = Get-Content -LiteralPath $sandbox.ReceiptPath -Raw | ConvertFrom-Json
            $receipt.status | Should -Be 'measured'
            @($receipt.trials)[0].exitCode | Should -Be 6
            @($receipt.trials)[0].error | Should -BeNullOrEmpty
        } finally {
            Remove-HarnessSandbox $sandbox
        }
    }

    It 'marks a trial failed when the pipeline reports a real error exit code' -Tag 'WindowsOnly' {
        $sandbox = New-HarnessSandbox -StubExitCode 1
        try {
            Invoke-HarnessRun -Sandbox $sandbox -Harness $harnessPath | Should -BeTrue

            $receipt = Get-Content -LiteralPath $sandbox.ReceiptPath -Raw | ConvertFrom-Json
            $receipt.status | Should -Be 'failed'
            @($receipt.trials)[0].error | Should -Be 'compression-process-failed'
        } finally {
            Remove-HarnessSandbox $sandbox
        }
    }
}
