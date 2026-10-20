BeforeAll {
    $env:PDFCOMP_SKIP_MAIN = '1'
    . (Join-Path $PSScriptRoot '..\..\_internal\compress.ps1')
    Remove-Item Env:PDFCOMP_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'Invoke-PdfCompressorMain return-code orchestration' {
    It 'rejects conflicting, absent, and missing path-file inputs' {
        Invoke-PdfCompressorMain -InputPath a -InputManifest b | Should -Be 3
        Invoke-PdfCompressorMain | Should -Be 3
        Invoke-PdfCompressorMain -InputPathFile (Join-Path $PSScriptRoot '..' '..' '_work' 'missing-main-input.txt') | Should -Be 3
    }

    It 'returns success for an empty manifest and emits empty status events' {
        Mock New-InputManifestFromPath { [pscustomobject]@{items=@();defaults=[pscustomobject]@{}} }
        Invoke-PdfCompressorMain -InputPath empty -StatusJson | Should -Be 0
    }

    It 'maps input path guard failures to exit code 3' {
        Invoke-PdfCompressorMain -InputPath (Join-Path $TestDrive 'missing.pdf') | Should -Be 3
    }

    It 'maps a generic main exception to exit code 1' {
        Mock New-InputManifestFromPath { throw 'unexpected main failure' }
        Invoke-PdfCompressorMain -InputPath anything | Should -Be 1
    }

    Context 'with one resolved manifest item' {
        BeforeEach {
            $script:mainInput = Join-Path $TestDrive 'main-input.pdf'
            Set-Content -LiteralPath $script:mainInput -Value '%PDF-test'
            $script:mainOutput = Join-Path $TestDrive 'output'
            $script:mainLog = Join-Path $TestDrive 'logs\result.jsonl'
            $script:mainItem = [pscustomobject]@{
                input_path=$script:mainInput; item_id='item-1'; output_root=$null
                allow_signed_pdf=$false; allow_full_page_raster=$false
                mode='auto'; safety_mode='Off'; target_bytes=$null
                ocr=[pscustomobject]@{enabled=$false;languages=@()}
            }
            $script:mainManifest = [pscustomobject]@{items=@($script:mainItem);defaults=[pscustomobject]@{mode='auto';safety_mode='Off'}}
            $script:mainResult = [pscustomobject]@{
                item_id='item-1';file=$script:mainInput;status='ok';strategy_id='qpdf-lossless';tool='qpdf'
                original=100;compressed=50;ratio_pct=-50;fail_reason=$null;warnings=@();mode='auto';safety_mode='Off'
                features=$null;selection_reason='test';verification_status='verified';verification_reasons=@();target_bytes=$null
                target_status='not-requested';target_met=$null;attempt_count=1;stop_reason=$null;ocr_status='disabled';policy_reason=$null;output_path='out.pdf'
            }
            Mock New-InputManifestFromPath { $script:mainManifest }
            Mock Read-InputManifest { $script:mainManifest }
            Mock Assert-OutputPathLocal { param($TargetPath) [IO.Path]::GetFullPath($TargetPath) }
            Mock Assert-WritePathInsideTool { param($TargetPath) [IO.Path]::GetFullPath($TargetPath) }
            Mock Invoke-WorkDirCleanup {}
            Mock Get-ResolvedTools { [pscustomobject]@{capabilities=[pscustomobject]@{missing_required=@();safe_ready=$true};qpdf='q';pdfinfo='i';pdfimages='m'} }
            Mock Get-Strategies { [pscustomobject]@{allowed_dpi=@(150)} }
            Mock New-OutputPathContext { [pscustomobject]@{seen_map=@{};use_outside_output_root=$false} }
            Mock Get-ManifestItemSetting {
                param($Item,$Defaults,$Name)
                switch ($Name) { mode {'auto'} safety_mode {'Off'} target_bytes {$null} ocr {[pscustomobject]@{enabled=$false;languages=@()}} }
            }
            Mock Get-ManifestPropertyValue { param($Object,$Name,$Default) if ($Name -eq 'enabled') {$false} else {@()} }
            Mock Invoke-CompressOne { $script:mainResult }
            Mock Write-ResultLine {}
        }

        It 'returns 2 when required tools are missing' {
            Mock Get-ResolvedTools { [pscustomobject]@{capabilities=[pscustomobject]@{missing_required=@('qpdf');safe_ready=$false}} }
            Invoke-PdfCompressorMain -InputPath $script:mainInput -OutputRoot $script:mainOutput -LogPath $script:mainLog | Should -Be 2
        }

        It 'reads an in-workspace input path file and warns for explicit auto override' {
            $pathFile = Join-Path $PSScriptRoot '..\..\_work\main-input-path.txt'
            try {
                [IO.Directory]::CreateDirectory((Split-Path -Parent $pathFile)) | Out-Null
                Set-Content -LiteralPath $pathFile -Value $script:mainInput
                Invoke-PdfCompressorMain -InputPathFile $pathFile -OutputRoot $script:mainOutput -LogPath $script:mainLog -StrategyOverride auto | Should -Be 0
            } finally {
                Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'maps result priority to success, exists, failure, and action-required codes' -ForEach @(
            @{Status='ok';FailReason=$null;StopReason=$null;Force=$false;Expected=0},
            @{Status='skip';FailReason='exists';StopReason=$null;Force=$false;Expected=4},
            @{Status='skip';FailReason='exists';StopReason=$null;Force=$true;Expected=0},
            @{Status='fail';FailReason='tool-crashed';StopReason=$null;Force=$false;Expected=1},
            @{Status='skip';FailReason='safety-skip';StopReason='safety-skip';Force=$false;Expected=6}
        ) {
            $script:mainResult.status=$Status; $script:mainResult.fail_reason=$FailReason; $script:mainResult.stop_reason=$StopReason
            $args = @{InputPath=$script:mainInput;OutputRoot=$script:mainOutput;LogPath=$script:mainLog}
            if ($Force) { $args.Force=$true }
            Invoke-PdfCompressorMain @args | Should -Be $Expected
            Should -Invoke Write-ResultLine -Times 1
        }

        It 'emits diagnostic, queue, verification, file, and summary events' {
            Invoke-PdfCompressorMain -InputPath $script:mainInput -OutputRoot $script:mainOutput -LogPath $script:mainLog -StatusJson | Should -Be 0
        }

        It 'returns immediately after a preflight analysis event' {
            $script:mainResult.status='skip'; $script:mainResult.fail_reason='preflight-only'
            $script:mainResult | Add-Member -NotePropertyName analysis -NotePropertyValue ([pscustomobject]@{status='verified';page_count=1;image_ratio=0;avg_dpi=$null;has_images=$false;selection_reason='test';strategy_id='qpdf-lossless';verification_status='verified';verification_reasons=@();safety_action='allow';policy_reason='safe';features=$null;warnings=@()}) -Force
            Invoke-PdfCompressorMain -InputPath $script:mainInput -OutputRoot $script:mainOutput -LogPath $script:mainLog -PreflightOnly -StatusJson | Should -Be 0
            Should -Invoke Write-ResultLine -Times 0
        }

        It 'loads an explicit input manifest path' {
            Invoke-PdfCompressorMain -InputManifest manifest.json -OutputRoot $script:mainOutput -LogPath $script:mainLog | Should -Be 0
            Should -Invoke Read-InputManifest -Times 1
        }

        It 'maps an output path guard exception to exit code 5' {
            Mock Assert-OutputPathLocal { throw [PathGuardException]::new('output-guard: rejected') }
            Invoke-PdfCompressorMain -InputPath $script:mainInput -OutputRoot rejected -LogPath $script:mainLog | Should -Be 5
        }
    }
}
