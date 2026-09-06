BeforeAll {
    $internal = Join-Path $PSScriptRoot '..\..\_internal'
    . (Join-Path $internal 'inspect_pdf_features.ps1')
    . (Join-Path $internal 'safety-policy.ps1')
    . (Join-Path $internal 'pdf-structure.ps1')
    . (Join-Path $internal 'validate_output.ps1')

    function New-TestFeatureResult {
        param([hashtable]$States = @{})
        $container = [ordered]@{}
        foreach ($name in @('digital_signature','encrypted','pdfa','pdfx','acroform','xfa','annotations','outlines','links','attachments','javascript','tagged','layers')) {
            $state = if ($States.ContainsKey($name)) { $States[$name] } else { 'absent' }
            $container[$name] = [pscustomobject]@{state=$state;evidence='test'}
        }
        [pscustomobject]@{features=$container}
    }
}

Describe 'feature detector measured states' {
    It 'creates stable states and matches explicit patterns' {
        $state = New-PdfFeatureState -State present -Evidence test -Detector unit -Version 2
        $state.state | Should -Be 'present'
        Test-PdfFeaturePattern -Text '/JavaScript' -Patterns @('/JS','/JavaScript') | Should -BeTrue
        Test-PdfFeaturePattern -Text '/None' -Patterns @('/JS') | Should -BeFalse
    }

    It 'walks nested JSON properties, booleans, and containers' {
        $obj = [pscustomobject]@{level=@([pscustomobject]@{encrypted=$false;attachments=@('a');empty=@()})}
        @(Get-PdfJsonPropertyStates $obj @('encrypted')).Count | Should -Be 1
        (Get-PdfJsonBooleanState $obj @('encrypted')).found | Should -BeTrue
        (Get-PdfJsonContainerPresence $obj @('attachments')).present | Should -BeTrue
        (Get-PdfJsonContainerPresence $obj @('empty')).present | Should -BeFalse
        (Get-PdfJsonContainerPresence $obj @('missing')).found | Should -BeFalse
        @(Get-PdfJsonPropertyStates $obj @('x') -Depth 25).Count | Should -Be 0
    }

    It 'maps unavailable, encrypted, failed, invalid, and unknown-version JSON' -ForEach @(
        @{State='unavailable';Text=$null;Reason='qpdf-not-found';Expected='unavailable';Warning='qpdf-unavailable'},
        @{State='encrypted';Text='';Reason='encrypted-input';Expected='present';Warning='encrypted-input'},
        @{State='indeterminate';Text='';Reason='qpdf-json-failed';Expected='indeterminate';Warning='qpdf-json-failed'},
        @{State='available';Text='{bad';Reason='qpdf-json-ok';Expected='indeterminate';Warning='qpdf-json-invalid'},
        @{State='available';Text='{"version":"99"}';Reason='qpdf-json-ok';Expected='indeterminate';Warning='qpdf-json-version-unknown'}
    ) {
        Mock Get-PdfQpdfJsonText { [pscustomobject]@{state=$State;text=$Text;reason=$Reason} }
        $result = Get-PdfFeatures -PdfPath x.pdf -QpdfExe qpdf.exe
        $result.features.encrypted.state | Should -Be $Expected
        $result.warnings | Should -Contain $Warning
    }

    It 'detects known-version boolean, container, and structural signals' {
        $json = @'
{"version":"2","encrypted":false,"hasacroform":true,"hasjavascript":true,"tagged":true,"haslayers":true,"annotations":[{"id":1}],"outlines":[],"attachments":["a"],"/FT":"/Sig","metadata":"PDF/A PDF/X /XFA /Link"}
'@
        Mock Get-PdfQpdfJsonText { [pscustomobject]@{state='available';text=$json;reason='ok'} }
        $result = Get-PdfFeatures -PdfPath x.pdf -QpdfExe qpdf.exe
        $result.features.encrypted.state | Should -Be 'absent'
        $result.features.digital_signature.state | Should -Be 'present'
        $result.features.acroform.state | Should -Be 'present'
        $result.features.javascript.state | Should -Be 'present'
        $result.features.annotations.state | Should -Be 'present'
        $result.features.attachments.state | Should -Be 'present'
        $result.features.outlines.state | Should -Be 'absent'
        $result.features.pdfa.state | Should -Be 'present'
        $result.features.pdfx.state | Should -Be 'present'
    }

    It 'records supplementary pdfsig no-signature and signature evidence' -ForEach @(
        @{Text='No signatures';Warning='pdfsig-reported-no-signatures';Evidence=$false;Throws=$false},
        @{Text='Signature 1 is valid';Warning=$null;Evidence=$true;Throws=$false},
        @{Text='detector failed';Warning='pdfsig-failed';Evidence=$false;Throws=$true}
    ) {
        Mock Get-PdfQpdfJsonText { [pscustomobject]@{state='available';text='{"version":"2","encrypted":false}';reason='ok'} }
        $pdfsig = Join-Path $TestDrive ("pdfsig-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
        if ($Throws) { Set-Content -LiteralPath $pdfsig -Value "throw '$Text'" }
        else { Set-Content -LiteralPath $pdfsig -Value ('"' + $Text + '"') }
        $result = Get-PdfFeatures -PdfPath x.pdf -QpdfExe qpdf.exe -PdfSigExe $pdfsig
        if ($Warning) { $result.warnings | Should -Contain $Warning }
        if ($Evidence) { $result.features.digital_signature.evidence | Should -Match 'supplementary detector' }
    }
}

Describe 'data-driven safety decisions' {
    It 'reads states from dictionaries, objects, direct properties, and missing values' {
        Get-PdfFeatureStateValue (New-TestFeatureResult @{encrypted='present'}) encrypted | Should -Be 'present'
        Get-PdfFeatureStateValue ([pscustomobject]@{encrypted='absent'}) encrypted | Should -Be 'absent'
        Get-PdfFeatureStateValue $null encrypted | Should -Be 'unavailable'
        Get-PdfFeatureStateValue ([pscustomobject]@{}) missing | Should -Be 'unavailable'
        (Get-SafetyPolicyAction (Get-SafetyPolicyDefinition) attachments Safe) | Should -Be 'preserve'
        (Get-SafetyPolicyAction (Get-SafetyPolicyDefinition) missing Safe) | Should -Be 'record'
    }

    It 'rejects encrypted and unapproved signed input' {
        (Get-SafetyDecision (New-TestFeatureResult @{encrypted='present'}) -StrategyId qpdf-lossless).reasons | Should -Contain 'encrypted'
        $signed = Get-SafetyDecision (New-TestFeatureResult @{digital_signature='present'}) -StrategyId qpdf-lossless
        $signed.action | Should -Be 'skip'
        $signed.reasons | Should -Contain 'signed-pdf'
    }

    It 'allows signed input only with an explicit preservation warning' {
        $result = Get-SafetyDecision (New-TestFeatureResult @{digital_signature='present'}) -StrategyId qpdf-lossless -AllowSignedPdf
        $result.action | Should -Be 'continue'
        $result.verification_status | Should -Be 'warning'
        $result.warnings | Should -Contain 'signed-pdf-explicitly-allowed-signature-not-preserved'
    }

    It 'handles present, indeterminate, unavailable, standards, and raster risks' {
        $present = New-TestFeatureResult @{acroform='present';attachments='present';pdfa='present'}
        $regen = Get-SafetyDecision $present -StrategyId gs-downsample-150
        $regen.preserve_features | Should -Contain 'attachments'
        $regen.preserve_features | Should -Contain 'pdfa'
        $regen.warnings | Should -Contain 'standards-regeneration-warning:pdfa'

        $rasterDenied = Get-SafetyDecision $present -StrategyId gs-raster-readable
        $rasterDenied.reasons | Should -Contain 'full-page-raster-consent-required'
        $rasterWarn = Get-SafetyDecision $present -StrategyId gs-raster-readable -SafetyMode Warn -AllowFullPageRaster
        $rasterWarn.action | Should -Be 'confirm'
        $rasterAccepted = Get-SafetyDecision $present -StrategyId gs-raster-readable -SafetyMode Off -AllowFullPageRaster -AllowReducedVerification
        $rasterAccepted.verification_status | Should -Be 'warning'

        $indeterminate = Get-SafetyDecision (New-TestFeatureResult @{acroform='indeterminate'}) -StrategyId qpdf-lossless
        $indeterminate.action | Should -Be 'skip'
        $indeterminate.reasons | Should -Contain 'feature-indeterminate:acroform'
        $unavailable = Get-SafetyDecision (New-TestFeatureResult @{digital_signature='unavailable'}) -StrategyId qpdf-lossless
        $unavailable.action | Should -Be 'unavailable'
        $unavailable.reasons | Should -Contain 'feature-unavailable:digital_signature'
        (Test-SafetyPolicy (New-TestFeatureResult) -StrategyId qpdf-lossless).allowed | Should -BeTrue
    }

    It 'executes generic skip and confirm directives from a supplied policy' -ForEach @(
        @{Mode='Safe';Directive='skip';Reduced=$false;Expected='skip'},
        @{Mode='Safe';Directive='confirm';Reduced=$false;Expected='skip'},
        @{Mode='Warn';Directive='confirm';Reduced=$false;Expected='confirm'},
        @{Mode='Warn';Directive='confirm';Reduced=$true;Expected='continue'}
    ) {
        $definition = [pscustomobject]@{Safe=$Directive;Warn=$Directive;Off='record'}
        $policy = [pscustomobject]@{version='test';raster_strategy_ids=@();regeneration_strategy_ids=@();required_detection_features=@();features=[pscustomobject]@{custom=$definition}}
        Mock Get-SafetyPolicyDefinition { $policy }
        $features = [pscustomobject]@{custom=[pscustomobject]@{state='present'}}
        $args = @{Features=$features;SafetyMode=$Mode;StrategyId='qpdf-lossless'}
        if ($Reduced) { $args.AllowReducedVerification=$true }
        (Get-SafetyDecision @args).action | Should -Be $Expected
    }

    It 'handles Warn-mode indeterminate and required unavailable consent branches' {
        $indeterminate = Get-SafetyDecision (New-TestFeatureResult @{acroform='indeterminate'}) -StrategyId qpdf-lossless -SafetyMode Warn
        $indeterminate.action | Should -Be 'confirm'
        (Get-SafetyDecision (New-TestFeatureResult @{acroform='indeterminate'}) -StrategyId qpdf-lossless -SafetyMode Warn -AllowReducedVerification).verification_status | Should -Be 'warning'
        $unavailable = Get-SafetyDecision (New-TestFeatureResult @{encrypted='unavailable'}) -StrategyId qpdf-lossless -SafetyMode Warn
        $unavailable.action | Should -Be 'confirm'
        (Get-SafetyDecision (New-TestFeatureResult @{encrypted='unavailable'}) -StrategyId qpdf-lossless -SafetyMode Warn -AllowReducedVerification).verification_status | Should -Be 'warning'
    }
}

Describe 'validation branch coverage' {
    BeforeEach {
        Mock Invoke-QpdfCheck { [pscustomobject]@{status='clean';exit_code=0;warnings=@();raw=''} }
    }

    It 'normalizes all warning categories and variable data' -ForEach @(
        @{Text='damaged xref C:\secret\a.pdf offset 99 object 2 0';Category='damaged-xref'},
        @{Text='syntax parse error';Category='syntax'},
        @{Text='stream warning';Category='stream'},
        @{Text='password encryption';Category='encryption'},
        @{Text='linear warning 0xABC';Category='linearization'},
        @{Text='odd warning';Category='unclassified-warning'}
    ) {
        (Normalize-QpdfWarning $Text).category | Should -Be $Category
    }

    It 'maps unavailable, input error, output error, and warning states' {
        Mock Invoke-QpdfCheck {
            param($QpdfExe,$PdfPath)
            if ($PdfPath -eq 'input.pdf') { [pscustomobject]@{status='warning';exit_code=3;warnings=@([pscustomobject]@{category='stream';severity='warning'});raw=''} }
            else { [pscustomobject]@{status='warning';exit_code=3;warnings=@([pscustomobject]@{category='syntax';severity='warning'},[pscustomobject]@{category='odd';severity='unknown'});raw=''} }
        }
        $safe = Validate-CompressedPdf input.pdf output.pdf qpdf.exe unused -SafetyMode Safe
        $safe.status | Should -Be 'rejected'
        $safe.reasons | Should -Contain 'unclassified-qpdf-warning'
        $safe.reasons | Should -Contain 'new-qpdf-warning:syntax'
        $warn = Validate-CompressedPdf input.pdf output.pdf qpdf.exe unused -SafetyMode Warn
        $warn.status | Should -Be 'warning'
    }

    It 'rejects structure mismatch and handles indeterminate structure by mode' {
        $before = [pscustomobject]@{status='indeterminate';page_count=1;pages=@([pscustomobject]@{media_box=@(0,0,10,10);crop_box=@(0,0,10,10);rotate=0})}
        $after = [pscustomobject]@{status='verified';page_count=1;pages=@([pscustomobject]@{media_box=@(0,0,11,10);crop_box=@(0,0,10,10);rotate=0})}
        $safe = Validate-CompressedPdf input.pdf output.pdf qpdf.exe unused -BeforeStructure $before -AfterStructure $after -SafetyMode Safe
        $safe.status | Should -Be 'rejected'
        $safe.reasons | Should -Contain 'media-box-mismatch'
        $safe.reasons | Should -Contain 'structure-indeterminate'
    }

    It 'applies preserve, warn, confirm, record, and signature-loss policy' {
        $before = New-TestFeatureResult @{attachments='present';acroform='present';digital_signature='present'}
        $after = New-TestFeatureResult @{attachments='absent';acroform='absent';digital_signature='absent'}
        $safe = Validate-CompressedPdf input.pdf output.pdf qpdf.exe unused -BeforeFeatures $before -AfterFeatures $after -SafetyMode Safe
        $safe.status | Should -Be 'rejected'
        $safe.reasons | Should -Contain 'feature-loss:attachments'
        $safe.reasons | Should -Contain 'feature-loss-warning:acroform'
        $safe.reasons | Should -Contain 'signature-preservation-not-claimed'
        $off = Validate-CompressedPdf input.pdf output.pdf qpdf.exe unused -BeforeFeatures $before -AfterFeatures $after -SafetyMode Off
        $off.accepted | Should -BeTrue
        $off.reasons | Should -Contain 'feature-loss-recorded:attachments'
    }

    It 'reads feature states from dictionary containers and missing results' {
        Get-FeatureStateFromResult $null attachments | Should -Be 'unavailable'
        Get-FeatureStateFromResult ([pscustomobject]@{features=@{attachments=[pscustomobject]@{state='present'}}}) attachments | Should -Be 'present'
        Get-FeatureStateFromResult ([pscustomobject]@{features=[pscustomobject]@{}}) attachments | Should -Be 'unavailable'
    }

    It 'maps unavailable and failed qpdf checks on each side' -ForEach @(
        @{InStatus='unavailable';OutStatus='clean';Expected='qpdf-input-unavailable'},
        @{InStatus='error';OutStatus='clean';Expected='qpdf-input-error'},
        @{InStatus='clean';OutStatus='unavailable';Expected='qpdf-unavailable'},
        @{InStatus='clean';OutStatus='tool-failure';Expected='qpdf-output-tool-failure'}
    ) {
        Mock Invoke-QpdfCheck { param($QpdfExe,$PdfPath) $status=if($PdfPath -eq 'input.pdf'){$InStatus}else{$OutStatus};[pscustomobject]@{status=$status;exit_code=$null;warnings=@();raw=''} }
        (Validate-CompressedPdf input.pdf output.pdf q unused).reasons | Should -Contain $Expected
    }

    It 'covers Warn indeterminate structure and confirmation feature loss' {
        $structure = [pscustomobject]@{status='indeterminate';page_count=1;pages=@([pscustomobject]@{media_box=@(0,0,10,10);crop_box=@(0,0,10,10);rotate=0})}
        (Validate-CompressedPdf input.pdf output.pdf q unused -BeforeStructure $structure -AfterStructure $structure -SafetyMode Warn).status | Should -Be 'indeterminate'
        Mock Get-ValidationFeaturePolicyAction { 'confirm' }
        $before = New-TestFeatureResult @{acroform='present'};$after=New-TestFeatureResult @{acroform='absent'}
        $result = Validate-CompressedPdf input.pdf output.pdf q unused -BeforeFeatures $before -AfterFeatures $after -SafetyMode Warn
        $result.status | Should -Be 'warning'
        $result.reasons | Should -Contain 'feature-loss-confirmation:acroform'
    }

}

Describe 'Invoke-QpdfCheck direct unavailable path' {
    It 'returns unavailable when the qpdf executable is absent' {
        (Invoke-QpdfCheck -QpdfExe (Join-Path $TestDrive missing.exe) -PdfPath input.pdf).status | Should -Be 'unavailable'
    }

    It 'maps an executable invocation exception to tool-failure' {
        $tool = Join-Path $TestDrive 'throwing-qpdf.ps1'; Set-Content -LiteralPath $tool -Value "throw 'qpdf invocation failed'"
        (Invoke-QpdfCheck -QpdfExe $tool -PdfPath input.pdf).status | Should -Be 'tool-failure'
        Get-ValidationFeaturePolicyAction -Name missing -SafetyMode Safe | Should -Be 'record'
    }
}
