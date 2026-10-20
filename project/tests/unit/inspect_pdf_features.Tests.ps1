Set-StrictMode -Version Latest

BeforeAll {
    $internalRoot = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internalRoot 'tool-resolver.ps1')
    . (Join-Path $internalRoot 'inspect_pdf_features.ps1')
    $script:qpdf = Find-ToolExecutable -Name 'qpdf'
    $script:fixture = Join-Path $PSScriptRoot '..\fixtures\pdf\minimal-text.pdf'
}

Describe 'qpdf JSON feature detector' -Tag 'ExternalTool' {
    It 'does not report empty qpdf v2 containers as present' {
        if (-not $script:qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $features = Get-PdfFeatures -PdfPath $script:fixture -QpdfExe $script:qpdf
        $features.features['acroform'].state | Should -Be 'absent'
        $features.features['attachments'].state | Should -Be 'absent'
        $features.features['outlines'].state | Should -Be 'absent'
    }

    It 'bounds qpdf JSON before parsing oversized output' {
        if (-not $script:qpdf) {
            Set-ItResult -Skipped -Because 'qpdf is not available'
            return
        }
        $result = Get-PdfQpdfJsonText -QpdfExe $script:qpdf -PdfPath $script:fixture -MaxBytes 1
        $result.state | Should -Be 'indeterminate'
        $result.reason | Should -Be 'qpdf-json-limit-exceeded'
        $result.text | Should -BeNullOrEmpty
    }
}

Describe 'qpdf JSON process wrapper without an installed qpdf' {
    BeforeAll {
        function New-FakeQpdfExecutable {
            param(
                [Parameter(Mandatory)][string]$Name,
                [string]$Stdout = '',
                [string]$Stderr = '',
                [int]$ExitCode = 0
            )
            if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                $path = Join-Path $TestDrive ($Name + '.cmd')
                $lines = @('@echo off')
                if ($Stdout) { $lines += ('echo ' + $Stdout) }
                if ($Stderr) { $lines += ('echo ' + $Stderr + ' 1>&2') }
                $lines += ('exit /b ' + $ExitCode)
                [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
            }
            else {
                $path = Join-Path $TestDrive $Name
                $lines = @('#!/bin/sh')
                if ($Stdout) { $lines += ("printf '%s\n' '" + $Stdout + "'") }
                if ($Stderr) { $lines += ("printf '%s\n' '" + $Stderr + "' 1>&2") }
                $lines += ('exit ' + $ExitCode)
                [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
                [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
            }
            return $path
        }
        $script:samplePdf = Join-Path $TestDrive 'sample.pdf'
        [IO.File]::WriteAllText($script:samplePdf, "%PDF-1.7`n")
    }

    It 'reports a missing qpdf executable as unavailable' {
        $result = Get-PdfQpdfJsonText -QpdfExe (Join-Path $TestDrive 'missing-qpdf.exe') -PdfPath $script:samplePdf
        $result.state | Should -Be 'unavailable'
        $result.reason | Should -Be 'qpdf-not-found'
        $result.text | Should -BeNullOrEmpty
    }

    It 'returns qpdf JSON text when the child exits successfully' {
        $fake = New-FakeQpdfExecutable -Name 'qpdf-ok' -Stdout '{"version":2}'
        $result = Get-PdfQpdfJsonText -QpdfExe $fake -PdfPath $script:samplePdf
        $result.state | Should -Be 'available'
        $result.reason | Should -Be 'qpdf-json-ok'
        $result.text.Trim() | Should -Be '{"version":2}'
    }

    It 'classifies a password failure reported on stderr as encrypted' {
        $fake = New-FakeQpdfExecutable -Name 'qpdf-encrypted' -Stderr 'invalid password' -ExitCode 2
        $result = Get-PdfQpdfJsonText -QpdfExe $fake -PdfPath $script:samplePdf
        $result.state | Should -Be 'encrypted'
        $result.reason | Should -Be 'encrypted-input'
    }

    It 'classifies any other nonzero exit as indeterminate' {
        $fake = New-FakeQpdfExecutable -Name 'qpdf-damaged' -Stderr 'damaged file' -ExitCode 2
        $result = Get-PdfQpdfJsonText -QpdfExe $fake -PdfPath $script:samplePdf
        $result.state | Should -Be 'indeterminate'
        $result.reason | Should -Be 'qpdf-json-failed'
    }

    It 'stops reading and discards output above the byte limit' {
        $fake = New-FakeQpdfExecutable -Name 'qpdf-large' -Stdout '{"version":2,"padding":"0123456789"}'
        $result = Get-PdfQpdfJsonText -QpdfExe $fake -PdfPath $script:samplePdf -MaxBytes 4
        $result.state | Should -Be 'indeterminate'
        $result.reason | Should -Be 'qpdf-json-limit-exceeded'
        $result.text | Should -BeNullOrEmpty
    }

    It 'fails closed when the qpdf path cannot be started' {
        $notExecutable = Join-Path $TestDrive 'not-an-executable.txt'
        [IO.File]::WriteAllText($notExecutable, 'not a program')
        $result = Get-PdfQpdfJsonText -QpdfExe $notExecutable -PdfPath $script:samplePdf
        $result.state | Should -Be 'indeterminate'
        $result.reason | Should -Be 'qpdf-json-exception'
        $result.text | Should -BeNullOrEmpty
    }
}
