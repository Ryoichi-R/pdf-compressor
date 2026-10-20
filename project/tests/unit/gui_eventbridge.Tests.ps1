BeforeAll {
    $script:toolRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:guiPs1   = Join-Path $script:toolRoot '_internal\gui.ps1'
    $script:compressPs1 = Join-Path $script:toolRoot '_internal\compress.ps1'
    $script:guiText  = Get-Content -Raw -LiteralPath $script:guiPs1
    $script:compressText = Get-Content -Raw -LiteralPath $script:compressPs1
}

Describe 'gui.ps1 Register-ObjectEvent Action body is self-contained' {
    BeforeAll {
        # Extract OutputDataReceived/ErrorDataReceived Action scriptblocks.
        $pattern = '(?ms)Register-ObjectEvent[^{]*-Action\s*\{(.*?)\}'
        $script:actionBodies = [regex]::Matches($script:guiText, $pattern) |
            ForEach-Object { $_.Groups[1].Value }
    }

    It 'extracts at least two Register-ObjectEvent Action blocks (stdout + stderr)' {
        $script:actionBodies.Count | Should -BeGreaterOrEqual 2
    }

    It 'Action body does not call script-scope helper functions' {
        foreach ($body in $script:actionBodies) {
            $body | Should -Not -Match 'Receive-StdoutLine'
            $body | Should -Not -Match 'Write-LogUI'
            $body | Should -Not -Match 'Invoke-StatusLine'
        }
    }

    It 'Action body enqueues into MessageData (ConcurrentQueue)' {
        foreach ($body in $script:actionBodies) {
            $body | Should -Match 'Enqueue'
            $body | Should -Match '\$Event\.MessageData'
        }
    }
}

Describe 'gui.ps1 declares queue-drain and cleanup helpers' {
    It 'defines Receive-OutputQueues helper (approved verb)' {
        $script:guiText | Should -Match 'function\s+Receive-OutputQueues'
    }

    It 'defines Clear-OutputEventBridge helper' {
        $script:guiText | Should -Match 'function\s+Clear-OutputEventBridge'
    }

    It 'calls Receive-OutputQueues from the DoEvents loop' {
        $script:guiText | Should -Match '(?ms)while\s*\(\s*\$script:ChildProc\s*-and\s*-not\s*\$script:ChildProc\.HasExited\s*\)\s*\{[^}]*Receive-OutputQueues'
    }

    It 'calls Clear-OutputEventBridge from a finally block (btnRun cleanup)' {
        $script:guiText | Should -Match '(?ms)finally\s*\{[^}]*Clear-OutputEventBridge'
    }

    It 'Start-CompressJob wraps register/start in try/catch that calls Clear-OutputEventBridge' {
        $script:guiText | Should -Match '(?ms)function\s+Start-CompressJob.*catch\s*\{[^}]*Clear-OutputEventBridge[^}]*throw'
    }
}

Describe 'gui.ps1 Invoke-Cancel ordering' {
    It 'requests cooperative stop before forced fallback and drains output before cleanup' {
        $script:guiText | Should -Match '(?ms)WriteAllText\(\$script:CancelFilePath[\s\S]*?AddSeconds\(5\)[\s\S]*?\.Kill\(\$true\)[\s\S]*?WaitForExit\(\)[\s\S]*?Receive-OutputQueues[\s\S]*?Clear-WorkSubdirs'
    }

    It 'writes aborted JSONL after queue drain' {
        $script:guiText | Should -Match '(?ms)Receive-OutputQueues[\s\S]*?Write-AbortedJsonl'
    }

    It 'sets an initial in-flight file and completes the queue before writing the aborted record' {
        $script:guiText | Should -Match '\$script:LastInFlightFile\s*=\s*if\s*\(\$readyPaths\.Count\s*-gt\s*0\)'
        $script:guiText | Should -Match '(?ms)Complete-GuiQueueCancellation[\s\S]*?Update-GuiQueueView[\s\S]*?Write-AbortedJsonl\s+-InFlightFile\s+\$cancelled\.in_flight_path'
    }

    It 'tracks file-start and aborted status events with file attribution' {
        $script:guiText | Should -Match "'file-start'\s*\{"
        $script:guiText | Should -Match "'aborted'\s*\{"
        $script:compressText | Should -Match 'event=''file-start'';\s*idx=\$idx;\s*file=\$file\.FullName'
        $script:compressText | Should -Match 'event=''aborted'';\s*reason=''cancel-marker'';\s*file=\[string\]\$item\.input_path'
    }

    It 'maps an aborted child file event to cancelled without counting a failure or duplicating JSONL' {
        $script:guiText | Should -Match '\$isAborted\s*=\s*\$status\s*-eq\s*''fail'''
        $script:guiText | Should -Match '(?ms)if\s*\(\$isAborted\).*?''cancelled'''
        $script:guiText | Should -Match '''fail''\s*\{\s*if\s*\(-not\s+\$isAborted\)\s*\{\s*\$script:FailCount\+\+'
        $script:guiText | Should -Match '(?ms)if\s*\(-not\s+\$script:ChildReportedAbort\)\s*\{\s*Write-AbortedJsonl'
    }

    It 'allows cancelled queue items to be selected and returned to running on retry' {
        $script:guiText | Should -Match "state\s*-in\s*@\('ready','cancelled'\)"
        $script:guiText | Should -Match '(?ms)if\s*\(\$item\.state\s*-eq\s*''cancelled''\).*?Set-GuiQueueItemState\s+-Item\s+\$item\s+-State\s+''ready''.*?Set-GuiQueueItemState\s+-Item\s+\$item\s+-State\s+''running'''
    }
}

Describe 'gui.ps1 ConcurrentQueue state variables' {
    It 'declares StdoutQueue / StderrQueue script state' {
        $script:guiText | Should -Match '\$script:StdoutQueue\s*='
        $script:guiText | Should -Match '\$script:StderrQueue\s*='
    }

    It 'instantiates ConcurrentQueue[string] in Start-CompressJob' {
        $script:guiText | Should -Match 'System\.Collections\.Concurrent\.ConcurrentQueue\[string\]'
    }

    It 'does not retain unused $script:ChildProcExited state variable' {
        $script:guiText | Should -Not -Match '\$script:ChildProcExited'
    }
}

Describe 'gui.ps1 lossy raster and output path UX behavior' {
    It 'offers lossy raster strategies in the strategy list' {
        $script:guiText | Should -Match "'gs-raster-low-quality'"
        $script:guiText | Should -Match "'gs-raster-readable'"
    }

    It 'declares lossy raster confirmation helper and suppression hook' {
        $script:guiText | Should -Match 'function\s+Confirm-LossyRasterRun'
        $script:guiText | Should -Match '\$script:SuppressLossyConfirm'
        $script:guiText | Should -Match 'gs-raster-low-quality'
        $script:guiText | Should -Match 'gs-raster-readable'
    }

    It 'does not dot-source path-guard.ps1 in the GUI' {
        $script:guiText | Should -Not -Match 'Join-Path\s+\$script:ScriptDir\s+''path-guard\.ps1'''
        $script:guiText | Should -Match 'function\s+Test-OutputPathLocalHint'
    }
}

Describe 'gui.ps1 preflight and diagnostic UX' {
    It 'wires asynchronous preflight, uncertainty confirmation, and diagnostic columns' {
        $script:guiText | Should -Match 'function\s+Start-GuiPreflightBatch'
        $script:guiText | Should -Match '-PreflightOnly'
        $script:guiText | Should -Match 'function\s+Update-SafetyConfirmationGate'
        foreach ($column in @('features', 'verification', 'reason', 'strategy', 'ocr', 'output', 'tool')) {
            $script:guiText | Should -Match ("Columns\.Add\('" + $column + "'")
        }
    }

    It 'offers an independent diagnostics dialog and uses the shared diagnostic implementation' {
        $script:guiText | Should -Match '\$btnDiagnostics\.Text\s*=\s*''診断'''
        $script:guiText | Should -Match 'function\s+Show-GuiDiagnosticsDialog'
        $script:guiText | Should -Match 'Get-PdfCompressorDiagnostics'
        $script:guiText | Should -Match '\. \$script:DiagnosticsPs1'
        $script:guiText | Should -Not -Match 'function\s+Get-GuiDiagnosticMessage'
    }
}

Describe 'gui.ps1 queue removal UX' {
    It 'offers button and Delete-key removal backed by stable queue item ids' {
        $script:guiText | Should -Match '\$btnRemoveInput\.Text\s*=\s*''選択を削除'''
        $script:guiText | Should -Match 'function\s+Remove-GuiSelectedQueueItems'
        $script:guiText | Should -Match 'Remove-GuiQueueItems\s+-Queue\s+\$script:Queue\s+-ItemIds'
        $script:guiText | Should -Match '\$dgvQueue\.Add_KeyDown'
        $script:guiText | Should -Match 'DataGridViewSelectionMode\]::FullRowSelect'
    }

    It 'keeps removal disabled while a child process is active' {
        $script:guiText | Should -Match '\$btnRemoveInput\.Enabled\s*=\s*\(-not\s+\[bool\]\$script:ChildProc'
        $script:guiText | Should -Match '診断または圧縮の実行中はキューから削除できません'
    }
}

Describe 'gui.ps1 validation reason UX' {
    It 'renders verification reason messages and retains reason codes in the queue result' {
        $script:guiText | Should -Match 'Get-DiagnosticMessage\s+-Code\s+\$_'
        $script:guiText | Should -Match "Name 'verification_reasons'"
    }

    It 'keeps an empty verification reason list countable under StrictMode' {
        $script:guiText | Should -Match '(?ms)\$reasonCodes\s*=\s*@\(\s*if\s*\(\$obj\.PSObject\.Properties\[''reasons''\]\)'
        $script:guiText | Should -Match '\$reasonCodes\.Count\s*-gt\s*0'
    }
}

Describe 'gui.ps1 source/result open controls' {
    It 'wires explicit source PDF, result PDF and output folder actions' {
        $script:guiText | Should -Match '\$btnOpenSource\.Text\s*=\s*''元PDFを開く'''
        $script:guiText | Should -Match '\$btnOpenResult\.Text\s*=\s*''結果PDFを開く'''
        $script:guiText | Should -Match '\$btnRevealSource\.Text\s*=\s*''元PDFの場所'''
        $script:guiText | Should -Match '\$btnRevealResult\.Text\s*=\s*''結果PDFの場所'''
        $script:guiText | Should -Match 'Open-GuiPath\s+-Path\s+\$path\s+-Label\s+''元PDF'''
        $script:guiText | Should -Match 'Open-GuiPath\s+-Path\s+\$path\s+-Label\s+''結果PDF'''
        $script:guiText | Should -Match '\$btnOpenOutput\.Add_Click'
        $script:guiText | Should -Match 'Show-GuiPathInExplorer\s+-Path\s+\$p\s+-Label\s+''出力先フォルダ'''
        $script:guiText | Should -Match 'Show-GuiPathInExplorer\s+-Path\s+\$path\s+-Label\s+''元PDF''\s+-SelectFile'
        $script:guiText | Should -Match 'Show-GuiPathInExplorer\s+-Path\s+\$path\s+-Label\s+''結果PDF''\s+-SelectFile'
        $openOutputHandler = [regex]::Match($script:guiText, '(?s)\$btnOpenOutput\.Add_Click\(\{(?<body>.*?)\}\)')
        $openOutputHandler.Success | Should -BeTrue
        $openOutputHandler.Groups['body'].Value | Should -Not -Match '\$script:LastOutputPath'
    }
}

Describe 'gui.ps1 strategy labels' {
    It 'shows user-facing Japanese labels instead of raw ids in the combo box' {
        $script:guiText | Should -Match '自動（おすすめ）'
        $script:guiText | Should -Match '強く圧縮（高DPIスキャン向け）'
        $script:guiText | Should -Match '最大圧縮・画像化（検索不可）'
        $script:guiText | Should -Match 'Get-StrategyLabel'
        $script:guiText | Should -Match 'Get-SelectedStrategyId'
    }

    It 'passes and saves the internal strategy id, not the display label' {
        $script:guiText | Should -Match 'Start-CompressJob[\s\S]*-StrategyArg\s+\$strategy'
        $script:guiText | Should -Match 'Settings\.lastStrategy\s*=\s*Get-SelectedStrategyId'
    }
}

Describe 'gui.ps1 compression ratio summary' {
    It 'tracks original/compressed bytes from file status events' {
        $script:guiText | Should -Match '\$script:TotalOriginalBytes'
        $script:guiText | Should -Match '\$script:TotalCompressedBytes'
        $script:guiText | Should -Match '\$script:RatioFileCount'
        $script:guiText | Should -Match "PSObject\.Properties\['original'\]"
        $script:guiText | Should -Match "PSObject\.Properties\['compressed'\]"
    }

    It 'renders a saved percentage in the summary label' {
        $script:guiText | Should -Match 'function\s+Format-UiSize'
        $script:guiText | Should -Match 'function\s+Get-CompressionSummaryText'
        $script:guiText | Should -Match 'saved=\{1\}%'
        $script:guiText | Should -Match 'AutoEllipsis'
    }
}
