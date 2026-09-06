# Copyright (c) 2026 Ryoichi-R
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

<#
.SYNOPSIS
    Detect PDF features with explicit four-state results.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PdfFeatureNames = @('digital_signature','encrypted','pdfa','pdfx','acroform','xfa','annotations','outlines','links','attachments','javascript','tagged','layers')

function New-PdfFeatureState {
    param([Parameter(Mandatory)][string]$State,[Parameter(Mandatory)][string]$Evidence,[string]$Detector = 'qpdf-json',[string]$Version = 'unknown')
    return [pscustomobject]@{ state = $State; evidence = $Evidence; detector = $Detector; detector_version = $Version }
}

function Get-PdfQpdfJsonText {
    param([Parameter(Mandatory)][string]$QpdfExe,[Parameter(Mandatory)][string]$PdfPath,[long]$MaxBytes = 67108864)
    if (-not (Test-Path -LiteralPath $QpdfExe -PathType Leaf)) { return [pscustomobject]@{ state = 'unavailable'; text = $null; reason = 'qpdf-not-found' } }
    $process = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $QpdfExe
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        [void]$psi.ArgumentList.Add('--json')
        [void]$psi.ArgumentList.Add('--')
        [void]$psi.ArgumentList.Add($PdfPath)
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        # Drain stderr asynchronously while stdout is bounded and read below.
        # Reading stdout to completion before touching stderr can deadlock when
        # a failing qpdf fills its stderr pipe.
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $reader = $process.StandardOutput
        $builder = [System.Text.StringBuilder]::new()
        $buffer = [char[]]::new(8192)
        $bytesRead = 0L
        $tooLarge = $false
        while (($count = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $chunk = [string]::new($buffer, 0, $count)
            $chunkBytes = [Text.Encoding]::UTF8.GetByteCount($chunk)
            if (($bytesRead + $chunkBytes) -gt $MaxBytes) { $tooLarge = $true; break }
            [void]$builder.Append($chunk)
            $bytesRead += $chunkBytes
        }
        if ($tooLarge) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
            try { $process.WaitForExit() } catch {}
            try { $null = $stderrTask.GetAwaiter().GetResult() } catch {}
            return [pscustomobject]@{ state = 'indeterminate'; text = $null; reason = 'qpdf-json-limit-exceeded' }
        }
        $process.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $rc = $process.ExitCode
        $text = $builder.ToString()
        if ($rc -ne 0) {
            $lower = ($text + "`n" + $stderr).ToLowerInvariant()
            if ($lower -match 'encrypt|password') { return [pscustomobject]@{ state = 'encrypted'; text = $text; reason = 'encrypted-input' } }
            return [pscustomobject]@{ state = 'indeterminate'; text = $text; reason = 'qpdf-json-failed' }
        }
        return [pscustomobject]@{ state = 'available'; text = $text; reason = 'qpdf-json-ok' }
    } catch { return [pscustomobject]@{ state = 'indeterminate'; text = $null; reason = 'qpdf-json-exception' } }
    finally {
        if ($process) { $process.Dispose() }
    }
}

function Test-PdfFeaturePattern {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string[]]$Patterns)
    foreach ($pattern in $Patterns) { if ($Text -match $pattern) { return $true } }
    return $false
}

function Get-PdfJsonPropertyStates {
    param([object]$Object,[Parameter(Mandatory)][string[]]$Names,[int]$Depth = 0)
    if ($null -eq $Object -or $Depth -gt 24) { return @() }
    $wanted = @($Names | ForEach-Object { $_.ToLowerInvariant() })
    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        $found = foreach ($entry in $Object) { Get-PdfJsonPropertyStates -Object $entry -Names $Names -Depth ($Depth + 1) }
        return @($found)
    }
    $found = @()
    foreach ($property in @($Object.PSObject.Properties)) {
        if ($wanted -contains $property.Name.ToLowerInvariant()) {
            $found += [pscustomobject]@{ name = $property.Name; value = $property.Value }
        }
        if ($null -ne $property.Value -and $property.Value -isnot [string]) {
            $found += @(Get-PdfJsonPropertyStates -Object $property.Value -Names $Names -Depth ($Depth + 1))
        }
    }
    return @($found)
}

function Get-PdfJsonBooleanState {
    param([Parameter(Mandatory)][object]$Object,[Parameter(Mandatory)][string[]]$Names)
    $matches = @(Get-PdfJsonPropertyStates -Object $Object -Names $Names)
    foreach ($match in $matches) {
        if ($match.value -is [bool]) { return [pscustomobject]@{ found = $true; value = [bool]$match.value } }
    }
    return [pscustomobject]@{ found = $false; value = $false }
}

function Get-PdfJsonContainerPresence {
    param([Parameter(Mandatory)][object]$Object,[Parameter(Mandatory)][string[]]$Names)
    $matches = @(Get-PdfJsonPropertyStates -Object $Object -Names $Names)
    if ($matches.Count -eq 0) { return [pscustomobject]@{ found = $false; present = $false } }
    foreach ($match in $matches) {
        $value = $match.value
        if ($null -eq $value) { continue }
        if ($value -is [string]) { if (-not [string]::IsNullOrWhiteSpace($value)) { return [pscustomobject]@{ found = $true; present = $true } } }
        elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { if (@($value).Count -gt 0) { return [pscustomobject]@{ found = $true; present = $true } } }
        elseif (@($value.PSObject.Properties).Count -gt 0) { return [pscustomobject]@{ found = $true; present = $true } }
    }
    return [pscustomobject]@{ found = $true; present = $false }
}

function Get-PdfFeatures {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [Parameter(Mandatory)][string]$QpdfExe,
        [string]$PdfSigExe,
        [string]$PdfDetachExe
    )
    $json = Get-PdfQpdfJsonText -QpdfExe $QpdfExe -PdfPath $PdfPath
    $features = [ordered]@{}
    foreach ($name in $script:PdfFeatureNames) {
        $features[$name] = New-PdfFeatureState -State 'unavailable' -Evidence 'qpdf unavailable' -Version 'unknown'
    }
    if ($json.state -eq 'unavailable') {
        return [pscustomobject]@{ detector = 'qpdf-json'; detector_version = 'unavailable'; features = $features; warnings = @('qpdf-unavailable') }
    }
    if ($json.state -eq 'encrypted') {
        $features.encrypted = New-PdfFeatureState -State 'present' -Evidence 'qpdf reported encrypted/password protected input'
        foreach ($name in $script:PdfFeatureNames | Where-Object { $_ -ne 'encrypted' }) {
            $features[$name] = New-PdfFeatureState -State 'indeterminate' -Evidence 'encrypted input prevents feature inspection'
        }
        return [pscustomobject]@{ detector = 'qpdf-json'; detector_version = 'available'; features = $features; warnings = @('encrypted-input') }
    }
    if ($json.state -ne 'available' -or [string]::IsNullOrEmpty($json.text)) {
        foreach ($name in $script:PdfFeatureNames) { $features[$name] = New-PdfFeatureState -State 'indeterminate' -Evidence $json.reason }
        return [pscustomobject]@{ detector = 'qpdf-json'; detector_version = 'unknown'; features = $features; warnings = @($json.reason) }
    }
    $text = $json.text
    $parsedJson = $null
    try { $parsedJson = $text | ConvertFrom-Json -ErrorAction Stop } catch {
        foreach ($name in $script:PdfFeatureNames) { $features[$name] = New-PdfFeatureState -State 'indeterminate' -Evidence 'qpdf JSON parse failed' }
        return [pscustomobject]@{ detector = 'qpdf-json'; detector_version = 'unknown'; features = $features; warnings = @('qpdf-json-invalid') }
    }
    $versionValue = $null
    $versionMatches = @(Get-PdfJsonPropertyStates -Object $parsedJson -Names @('version','jsonversion'))
    $versionEntry = $versionMatches | Where-Object { $_.name -in @('version','jsonversion') } | Select-Object -First 1
    if ($versionEntry) { $versionValue = $versionEntry.value }
    $version = if ($null -ne $versionValue) { [string]$versionValue } else { 'unknown' }
    # qpdf currently publishes JSON version 2.  Keep unknown keys forward
    # compatible, but do not interpret an unknown JSON schema as feature
    # absence: the safe result is indeterminate until the schema is supported.
    $knownJsonVersion = $version -in @('1','2')
    if (-not $knownJsonVersion) {
        foreach ($name in $script:PdfFeatureNames) {
            $features[$name] = New-PdfFeatureState -State 'indeterminate' -Evidence 'unsupported qpdf JSON version' -Version $version
        }
        return [pscustomobject]@{ detector = 'qpdf-json'; detector_version = $version; features = $features; warnings = @('qpdf-json-version-unknown') }
    }
    $encryptedSignal = Get-PdfJsonBooleanState -Object $parsedJson -Names @('encrypted')
    $encryptedState = if ($encryptedSignal.found) {
        if ($encryptedSignal.value) { 'present' } else { 'absent' }
    } elseif ($text -match '(?i)/Encrypt') { 'present' } else { 'indeterminate' }
    $features.encrypted = New-PdfFeatureState -State $encryptedState -Evidence 'qpdf JSON encrypted boolean or explicit encryption marker' -Version $version
    $signature = Test-PdfFeaturePattern $text @('SigFlags[^0-9]*[13579]','"(?:/)?FT"\s*:\s*"(?:/)?Sig"','/DocMDP','/UR3','"(?:/)?Sig"')
    $signatureState = if ($signature) { 'present' } else { 'absent' }
    $features.digital_signature = New-PdfFeatureState -State $signatureState -Evidence 'qpdf JSON signature object/permission inspection' -Version $version
    $signals = @{
        pdfa = @{ patterns = @('PDF/A','PDFA') }
        pdfx = @{ patterns = @('PDF/X','PDFX') }
        acroform = @{ boolean = @('hasacroform'); patterns = @('/AcroForm') }
        xfa = @{ patterns = @('/XFA') }
        annotations = @{ containers = @('annotations','annots'); patterns = @('/Annots') }
        outlines = @{ containers = @('outlines'); patterns = @('/Outlines') }
        links = @{ containers = @('links'); patterns = @('/Link') }
        attachments = @{ containers = @('attachments','embeddedfiles'); patterns = @('/EmbeddedFiles') }
        javascript = @{ boolean = @('hasjavascript'); patterns = @('/JavaScript','/JS') }
        tagged = @{ boolean = @('tagged'); patterns = @('/StructTreeRoot','/MarkInfo') }
        layers = @{ boolean = @('hasocproperties','haslayers'); patterns = @('/OCProperties','/OCG') }
    }
    foreach ($name in $signals.Keys) {
        $definition = $signals[$name]
        $featureState = 'absent'
        $evidence = 'qpdf JSON exact feature signal inspection'
        if ($definition.ContainsKey('boolean')) {
            $booleanSignal = Get-PdfJsonBooleanState -Object $parsedJson -Names $definition.boolean
            if ($booleanSignal.found) { $featureState = if ($booleanSignal.value) { 'present' } else { 'absent' } }
            elseif (Test-PdfFeaturePattern -Text $text -Patterns $definition.patterns) { $featureState = 'present'; $evidence = 'qpdf JSON explicit structural marker' }
            else { $featureState = 'absent'; $evidence = 'qpdf JSON exact signal not present' }
        } elseif ($definition.ContainsKey('containers')) {
            $containerSignal = Get-PdfJsonContainerPresence -Object $parsedJson -Names $definition.containers
            if ($containerSignal.found) { $featureState = if ($containerSignal.present) { 'present' } else { 'absent' } }
            elseif (Test-PdfFeaturePattern -Text $text -Patterns $definition.patterns) { $featureState = 'present'; $evidence = 'qpdf JSON explicit structural marker' }
            else { $featureState = 'absent' }
        } elseif (Test-PdfFeaturePattern -Text $text -Patterns $definition.patterns) {
            $featureState = 'present'; $evidence = 'qpdf JSON explicit metadata marker'
        }
        $features[$name] = New-PdfFeatureState -State $featureState -Evidence $evidence -Version $version
    }
    $warnings = @()
    if ($version -eq 'unknown') { $warnings += 'qpdf-json-version-unknown' }
    if ($PdfSigExe -and (Test-Path -LiteralPath $PdfSigExe)) {
        try {
            $sigOut = @(& $PdfSigExe '--' $PdfPath 2>&1)
            if (($sigOut -join "`n") -match '(?i)no signatures') { $warnings += 'pdfsig-reported-no-signatures' }
            elseif (($sigOut -join "`n") -match '(?i)signature') { $features.digital_signature.evidence += '; pdfsig supplementary detector' }
        } catch { $warnings += 'pdfsig-failed' }
    }
    return [pscustomobject]@{ detector = 'qpdf-json'; detector_version = $version; features = $features; warnings = @($warnings) }
}
