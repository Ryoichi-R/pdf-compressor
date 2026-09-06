Set-StrictMode -Version Latest

BeforeAll {
    $internalRoot = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internalRoot 'path-guard.ps1')
    . (Join-Path $internalRoot 'output-path.ps1')
    . (Join-Path $internalRoot 'tool-resolver.ps1')
    . (Join-Path $internalRoot 'tool-capabilities.ps1')
    . (Join-Path $internalRoot 'select_strategy.ps1')
    . (Join-Path $internalRoot 'pdf-structure.ps1')
    . (Join-Path $internalRoot 'inspect_pdf_features.ps1')
    . (Join-Path $internalRoot 'safety-policy.ps1')
    . (Join-Path $internalRoot 'target-size.ps1')
    . (Join-Path $internalRoot 'gui-queue.ps1')
    . (Join-Path $internalRoot 'input-manifest.ps1')
    $strategyConfig = Get-Strategies -JsonPath (Join-Path $internalRoot 'data\strategies.json')
}

Describe 'Public v1 input and output safety contracts' {
    It 'accepts an absolute PDF and rejects relative or non-PDF inputs' {
        $pdf = Join-Path $TestDrive 'input.pdf'
        Set-Content -LiteralPath $pdf -Value '%PDF-1.4' -Encoding ascii
        (Test-InputPathReadable -InputPath $pdf) | Should -BeTrue
        { Assert-InputPathReadable -InputPath 'relative.pdf' } | Should -Throw '*input-guard*'
        { Assert-InputPathReadable -InputPath (Join-Path $TestDrive 'input.txt') } | Should -Throw '*input-guard*'
    }

    # path-guard がドライブレター root を要求するため Windows 専用。
    It 'keeps output derivation item-scoped and collision-safe' -Tag 'WindowsOnly' {
        $output = Join-Path $TestDrive 'output'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $source = 'C:\src\dir'
        $a = [System.IO.FileInfo]::new('C:\src\dir\foo .pdf')
        $b = [System.IO.FileInfo]::new('C:\src\dir\foo.pdf')
        $ctx = New-OutputPathContext -SourceRoot $source -OutputRoot $output -UseOutsideOutputRoot:$true
        $seen = @{}
        $first = Resolve-OutputPath -Pdf $a -Context $ctx -SeenMap ([ref]$seen)
        $second = Resolve-OutputPath -Pdf $b -Context $ctx -SeenMap ([ref]$seen)
        $first | Should -Not -Be $second
        (Test-OutputPathLocal -TargetPath $first) | Should -BeTrue
    }
}

Describe 'Public v1 manifest and consent binding' {
    It 'rejects risky hand-written manifests without a current run nonce' {
        $work = Join-Path $TestDrive 'work\run-a'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $pdf = Join-Path $work 'signed.pdf'
        Set-Content -LiteralPath $pdf -Value '%PDF-1.4' -Encoding ascii
        $manifestPath = Join-Path $work 'input.manifest.json'
        [ordered]@{
            version = '1.0'
            defaults = [ordered]@{ mode = 'auto'; safety_mode = 'Safe'; target_bytes = $null; ocr = [ordered]@{ enabled = $false; languages = @() } }
            items = @([ordered]@{ input_path = $pdf; allow_signed_pdf = $true })
            risk_consent = [ordered]@{ nonce = ('a' * 32); work_dir = $work }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        { Read-InputManifest -Path $manifestPath -AllowRiskConsents -WorkRoot (Join-Path $TestDrive 'work') -ConsentNonce ('b' * 32) } | Should -Throw '*nonce*'
        $manifest = Read-InputManifest -Path $manifestPath -AllowRiskConsents -WorkRoot (Join-Path $TestDrive 'work') -ConsentNonce ('a' * 32)
        $manifest.items.Count | Should -Be 1
        $manifest.items[0].allow_signed_pdf | Should -BeTrue
    }

    It 'applies defaults while retaining per-item overrides' {
        $pdf = Join-Path $TestDrive 'item.pdf'
        Set-Content -LiteralPath $pdf -Value '%PDF-1.4' -Encoding ascii
        $manifest = New-InputManifestFromPath -InputPath $pdf -Mode 'minimum-size' -SafetyMode 'Warn' -TargetBytes 50000
        (Get-ManifestItemSetting -Item $manifest.items[0] -Defaults $manifest.defaults -Name 'mode') | Should -Be 'minimum-size'
        (Get-ManifestItemSetting -Item $manifest.items[0] -Defaults $manifest.defaults -Name 'safety_mode') | Should -Be 'Warn'
        (Get-ManifestItemSetting -Item $manifest.items[0] -Defaults $manifest.defaults -Name 'target_bytes') | Should -Be 50000
        $manifest.items[0].item_id | Should -Match '^[0-9a-f]{32}$'
    }
}

Describe 'Public v1 safety and structure policy' {
    It 'skips signed PDFs by default and requires raster consent' {
        $features = [pscustomobject]@{ features = [pscustomobject]@{
            digital_signature = [pscustomobject]@{ state = 'present' }
            encrypted = [pscustomobject]@{ state = 'absent' }
        } }
        $signed = Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'qpdf-lossless'
        $signed.action | Should -Be 'skip'
        $signed.policy_reason | Should -Match 'signed-pdf'
        $allowed = Get-SafetyDecision -Features $features -SafetyMode Warn -StrategyId 'qpdf-lossless' -AllowSignedPdf
        $allowed.action | Should -Be 'continue'
        $raster = Get-SafetyDecision -Features ([pscustomobject]@{ features = [pscustomobject]@{
            digital_signature = [pscustomobject]@{ state = 'absent' }
            encrypted = [pscustomobject]@{ state = 'absent' }
        } }) -SafetyMode Safe -StrategyId 'gs-raster-readable'
        $raster.action | Should -Be 'skip'
        $raster.policy_reason | Should -Match 'full-page-raster'
    }

    It 'does not classify unavailable feature detection as absent' {
        $features = [pscustomobject]@{ features = [pscustomobject]@{
            digital_signature = [pscustomobject]@{ state = 'unavailable' }
            encrypted = [pscustomobject]@{ state = 'unavailable' }
        } }
        $decision = Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'qpdf-lossless'
        $decision.action | Should -Be 'unavailable'
        $decision.verification_status | Should -Be 'unavailable'
    }

    It 'applies feature actions from safety-policy.json' {
        $features = [pscustomobject]@{ features = [pscustomobject]@{
            digital_signature = [pscustomobject]@{ state = 'absent' }
            encrypted = [pscustomobject]@{ state = 'absent' }
            acroform = [pscustomobject]@{ state = 'present' }
            tagged = [pscustomobject]@{ state = 'present' }
            javascript = [pscustomobject]@{ state = 'present' }
            layers = [pscustomobject]@{ state = 'present' }
            attachments = [pscustomobject]@{ state = 'present' }
        } }
        $safe = Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'qpdf-lossless'
        $safe.action | Should -Be 'continue'
        $safe.warnings | Should -Contain 'feature-present:acroform'
        $safe.warnings | Should -Contain 'feature-present:javascript'
        $safe.preserve_features | Should -Contain 'attachments'

        $raster = Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'gs-raster-readable' -AllowFullPageRaster
        $raster.action | Should -Be 'skip'
        $raster.policy_reason | Should -Match 'full-page-raster-feature:(acroform|tagged|attachments)'

        $off = Get-SafetyDecision -Features $features -SafetyMode Off -StrategyId 'qpdf-lossless'
        $off.action | Should -Be 'continue'
        $off.warnings | Should -Not -Contain 'feature-present:javascript'
    }

    It 'does not treat qpdf empty feature containers as present' {
        $json = '{"acroform":{"fields":[],"hasacroform":false},"attachments":{},"outlines":[]}' | ConvertFrom-Json
        $acroform = Get-PdfJsonBooleanState -Object $json -Names @('hasacroform')
        $attachments = Get-PdfJsonContainerPresence -Object $json -Names @('attachments')
        $outlines = Get-PdfJsonContainerPresence -Object $json -Names @('outlines')
        $acroform.found | Should -BeTrue
        $acroform.value | Should -BeFalse
        $attachments.found | Should -BeTrue
        $attachments.present | Should -BeFalse
        $outlines.found | Should -BeTrue
        $outlines.present | Should -BeFalse
    }

    It 'warns when a Ghostscript regeneration strategy handles PDF/A or PDF/X' {
        $features = [pscustomobject]@{ features = [pscustomobject]@{
            digital_signature = [pscustomobject]@{ state = 'absent' }
            encrypted = [pscustomobject]@{ state = 'absent' }
            pdfa = [pscustomobject]@{ state = 'present' }
            pdfx = [pscustomobject]@{ state = 'present' }
        } }
        $decision = Get-SafetyDecision -Features $features -SafetyMode Safe -StrategyId 'gs-downsample-150'
        $decision.warnings | Should -Contain 'standards-regeneration-warning:pdfa'
        $decision.warnings | Should -Contain 'standards-regeneration-warning:pdfx'
        $decision.preserve_features | Should -Contain 'pdfa'
        $decision.preserve_features | Should -Contain 'pdfx'
    }

    It 'detects page-box and rotation changes in a normalized snapshot' {
        $before = [pscustomobject]@{ page_count = 1; pages = @([pscustomobject]@{ media_box = @(0,0,612,792); crop_box = @(0,0,612,792); rotate = 0 }) }
        $same = [pscustomobject]@{ page_count = 1; pages = @([pscustomobject]@{ media_box = @(0,0,612,792.001); crop_box = @(0,0,612,792); rotate = 360 }) }
        (Compare-PdfStructureSnapshot -Before $before -After $same).equal | Should -BeTrue
        $changed = [pscustomobject]@{ page_count = 1; pages = @([pscustomobject]@{ media_box = @(0,0,600,792); crop_box = @(0,0,612,792); rotate = 90 }) }
        $comparison = Compare-PdfStructureSnapshot -Before $before -After $changed
        $comparison.equal | Should -BeFalse
        $comparison.reasons | Should -Contain 'media-box-mismatch'
        $comparison.reasons | Should -Contain 'rotate-mismatch'
    }
}

Describe 'Public v1 target and GUI queue contracts' {
    It 'selects the highest quality valid candidate that meets the target' {
        $candidates = @(
            [pscustomobject]@{ valid = $true; bytes = 900; quality_rank = 1 }
            [pscustomobject]@{ valid = $true; bytes = 700; quality_rank = 2 }
            [pscustomobject]@{ valid = $true; bytes = 500; quality_rank = 3 }
        )
        $result = Select-BestTargetCandidate -Candidates $candidates -TargetBytes 800 -OriginalBytes 2000 -MaxAttempts 7
        $result.target_status | Should -Be 'met'
        $result.selected.quality_rank | Should -Be 2
        (Test-TargetBytes -TargetBytes 0) | Should -BeFalse
        (Test-TargetBytes -TargetBytes 800) | Should -BeTrue
    }

    It 'reports target-not-met while retaining the smallest valid candidate' {
        $candidates = @(
            [pscustomobject]@{ valid = $true; bytes = 900; quality_rank = 1 }
            [pscustomobject]@{ valid = $true; bytes = 850; quality_rank = 2 }
        )
        $result = Select-BestTargetCandidate -Candidates $candidates -TargetBytes 800 -OriginalBytes 2000 -MaxAttempts 7
        $result.target_status | Should -Be 'not-met'
        $result.target_met | Should -BeFalse
        $result.selected.bytes | Should -Be 850
        $result.stop_reason | Should -Be 'target-not-met'
    }

    It 'enables Run only when a ready item and all safety gates are satisfied' {
        $queue = New-GuiQueueState
        $item = New-GuiQueueItem -InputPath (Join-Path $TestDrive 'queue.pdf')
        $queue.items.Add($item)
        $button = [pscustomobject]@{ Enabled = $false }
        (Test-RunAvailability -Queue $queue).enabled | Should -BeFalse
        Set-GuiQueueItemState -Item $item -State 'ready' | Out-Null
        (Update-RunAvailability -Queue $queue -Button $button).enabled | Should -BeTrue
        (Test-RunAvailability -Queue $queue -OutputValid:$false).reasons | Should -Contain 'invalid-output'

        Set-GuiQueueItemState -Item $item -State 'cancelled' | Out-Null
        (Test-RunAvailability -Queue $queue).enabled | Should -BeTrue
        Set-GuiQueueItemState -Item $item -State 'ready' | Out-Null
        $item.state | Should -Be 'ready'
    }

    It 'moves every running item to cancelled and retains the in-flight path' {
        $queue = New-GuiQueueState
        $items = 1..3 | ForEach-Object {
            $item = New-GuiQueueItem -InputPath (Join-Path $TestDrive ("cancel-{0}.pdf" -f $_))
            Add-GuiQueueItem -Queue $queue -Item $item | Out-Null
            Set-GuiQueueItemState -Item $item -State 'ready' | Out-Null
            Set-GuiQueueItemState -Item $item -State 'running' | Out-Null
            $item
        }

        $result = Complete-GuiQueueCancellation -Queue $queue -InFlightPath $items[1].input_path

        $result.in_flight_path | Should -Be $items[1].input_path
        $result.cancelled_count | Should -Be 3
        @($queue.items | ForEach-Object state) | Should -Be @('cancelled','cancelled','cancelled')
        (Get-GuiQueueProgress -Queue $queue).done | Should -Be 3
        (Get-GuiQueueProgress -Queue $queue).running | Should -Be 0
    }

    It 'uses the first running item when no in-flight path was received' {
        $queue = New-GuiQueueState
        $item = New-GuiQueueItem -InputPath (Join-Path $TestDrive 'cancel-fallback.pdf')
        Add-GuiQueueItem -Queue $queue -Item $item | Out-Null
        Set-GuiQueueItemState -Item $item -State 'ready' | Out-Null
        Set-GuiQueueItemState -Item $item -State 'running' | Out-Null

        $result = Complete-GuiQueueCancellation -Queue $queue

        $result.in_flight_path | Should -Be $item.input_path
        $item.state | Should -Be 'cancelled'
    }

    It 'counts a child-reported cancellation together with remaining running items' {
        $queue = New-GuiQueueState
        $items = 1..2 | ForEach-Object {
            $item = New-GuiQueueItem -InputPath (Join-Path $TestDrive ("child-abort-{0}.pdf" -f $_))
            Add-GuiQueueItem -Queue $queue -Item $item | Out-Null
            Set-GuiQueueItemState -Item $item -State 'ready' | Out-Null
            Set-GuiQueueItemState -Item $item -State 'running' | Out-Null
            $item
        }
        Set-GuiQueueItemState -Item $items[0] -State 'cancelled' | Out-Null

        $result = Complete-GuiQueueCancellation -Queue $queue -InFlightPath $items[0].input_path

        $result.cancelled_count | Should -Be 2
        @($queue.items | Where-Object state -eq 'cancelled').Count | Should -Be 2
    }

    It 'removes multiple selected queue items by stable item id' {
        $queue = New-GuiQueueState
        $items = 1..3 | ForEach-Object {
            $item = New-GuiQueueItem -InputPath (Join-Path $TestDrive ("queue-{0}.pdf" -f $_))
            Add-GuiQueueItem -Queue $queue -Item $item | Out-Null
            $item
        }
        $removed = Remove-GuiQueueItems -Queue $queue -ItemIds @($items[0].item_id, $items[2].item_id)
        $removed.removed_count | Should -Be 2
        @($removed.items | ForEach-Object item_id) | Should -Be @($items[0].item_id, $items[2].item_id)
        $queue.items.Count | Should -Be 1
        $queue.items[0].item_id | Should -Be $items[1].item_id

        (Remove-GuiQueueItems -Queue $queue -ItemIds @('missing')).removed_count | Should -Be 0
        $queue.items.Count | Should -Be 1
    }
}
