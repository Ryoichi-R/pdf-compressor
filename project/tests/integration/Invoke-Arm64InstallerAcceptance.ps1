[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Arm64Candidate,
    [Parameter(Mandatory)][string]$OutputRoot,
    [switch]$Arm64Only
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..\..')).TrimEnd('\')
$outputRootFull = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$candidateFull = [IO.Path]::GetFullPath($Arm64Candidate).TrimEnd('\')
if (-not $outputRootFull.StartsWith($workspaceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputRoot must remain under the workspace root.'
}
if (Test-Path -LiteralPath $outputRootFull) { throw "OutputRoot already exists: $outputRootFull" }
if (-not (Test-Path -LiteralPath $candidateFull -PathType Container)) { throw "ARM64 candidate not found: $candidateFull" }

function Get-InstallState([string]$Parent) {
    $installRoot = Join-Path $Parent 'PDF Compressor'
    $normalized = [IO.Path]::GetFullPath($installRoot).TrimEnd('\').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))) -replace '-', '').Substring(0, 24)
    } finally { $sha.Dispose() }
    $localRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'pdf-compressor'
    [pscustomobject]@{
        installRoot = $installRoot
        stateRoot = Join-Path $localRoot "runtime-state\$hash"
        backupRoot = Join-Path $localRoot "backups\$hash"
    }
}

function New-TestPackage([string]$Destination,[string]$Manifest,[string[]]$Artifacts) {
    $installerRoot = Join-Path $Destination 'project\installer'
    $payloadRoot = Join-Path $installerRoot 'payload'
    [IO.Directory]::CreateDirectory($payloadRoot) | Out-Null
    foreach ($name in @(
        'Install-PdfCompressor.ps1', 'Installer.Storage.ps1', 'Test-Payload.ps1',
        'Test-PayloadManifest.ps1', 'payload-manifest.schema.json', 'portable-dependencies.json'
    )) {
        Copy-Item -LiteralPath (Join-Path $projectRoot "installer\$name") -Destination (Join-Path $installerRoot $name)
    }
    Copy-Item -LiteralPath $Manifest -Destination (Join-Path $payloadRoot 'payload-manifest.json')
    foreach ($artifact in $Artifacts) {
        $destinationPath = Join-Path $payloadRoot (Split-Path -Leaf $artifact)
        New-Item -Path $destinationPath -ItemType HardLink -Target $artifact | Out-Null
    }
    return $installerRoot
}

function Invoke-TestInstaller(
    [string]$InstallerRoot,
    [string]$Runtime,
    [string]$Parent,
    [switch]$AllowRuntimeSwitch,
    [int]$FailAfterFiles = 0
) {
    $previousParent = $env:PDF_COMPRESSOR_INSTALL_PARENT
    try {
        $env:PDF_COMPRESSOR_INSTALL_PARENT = $Parent
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $InstallerRoot 'Install-PdfCompressor.ps1'), '-Runtime', $Runtime, '-NoOpen'
        )
        if ($AllowRuntimeSwitch) { $arguments += '-AllowRuntimeSwitch' }
        if ($FailAfterFiles -gt 0) { $arguments += @('-TestFailAfterFiles', [string]$FailAfterFiles) }
        $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments 2>&1
        [pscustomobject]@{ exitCode = $LASTEXITCODE; output = @($output | ForEach-Object { [string]$_ }) }
    } finally {
        if ($null -eq $previousParent) {
            Remove-Item Env:PDF_COMPRESSOR_INSTALL_PARENT -ErrorAction SilentlyContinue
        } else {
            $env:PDF_COMPRESSOR_INSTALL_PARENT = $previousParent
        }
    }
}

function Assert-Exit([object]$Result,[int]$Expected,[string]$Case) {
    if ($Result.exitCode -ne $Expected) {
        throw "$Case returned exit $($Result.exitCode), expected $Expected. Output: $($Result.output -join ' | ')"
    }
}

function Get-Marker([string]$InstallRoot) {
    Get-Content -LiteralPath (Join-Path $InstallRoot '.pdf-compressor-install.json') -Raw | ConvertFrom-Json
}

function Assert-RequiredMachine([string]$InstallRoot,[int]$ExpectedMachine) {
    foreach ($relative in @(
        'PdfCompressor.App.exe', 'runtime\pwsh\pwsh.exe', 'runtime\tools\qpdf.exe',
        'runtime\tools\pdfinfo.exe', 'runtime\tools\pdfimages.exe',
        'runtime\ghostscript\bin\gswin64c.exe'
    )) {
        $path = Join-Path $InstallRoot $relative
        $stream = [IO.File]::OpenRead($path)
        try {
            $reader = [IO.BinaryReader]::new($stream)
            if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE file: $relative" }
            $stream.Position = 0x3C
            $peOffset = $reader.ReadInt32()
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $relative" }
            $actual = $reader.ReadUInt16()
            if ($actual -ne $ExpectedMachine) { throw "PE machine mismatch for $relative`: $actual" }
        } finally { $stream.Dispose() }
    }
}

[IO.Directory]::CreateDirectory($outputRootFull) | Out-Null
$packageRoot = Join-Path $outputRootFull 'packages'
$installRoot = Join-Path $outputRootFull 'installs'
[IO.Directory]::CreateDirectory($packageRoot) | Out-Null
[IO.Directory]::CreateDirectory($installRoot) | Out-Null

$armManifest = Join-Path $candidateFull 'payload-manifest.json'
$armManifestObject = Get-Content -LiteralPath $armManifest -Raw | ConvertFrom-Json
$armPayload = $armManifestObject.payloads.'win-arm64'
$armArtifacts = @(
    (Join-Path $candidateFull $armPayload.archive),
    (Join-Path $candidateFull $armPayload.build.correspondingSource.archive)
)
$armInstaller = New-TestPackage -Destination (Join-Path $packageRoot 'arm64') -Manifest $armManifest -Artifacts $armArtifacts

$x64Payload = $null
$x64Installer = $null
if (-not $Arm64Only) {
    $canonicalRoot = Join-Path $projectRoot 'installer\payload'
    $x64Manifest = Join-Path $canonicalRoot 'payload-manifest.json'
    $x64ManifestObject = Get-Content -LiteralPath $x64Manifest -Raw | ConvertFrom-Json
    $x64Payload = $x64ManifestObject.payloads.'win-x64'
    $x64Artifacts = @((Join-Path $canonicalRoot $x64Payload.archive))
    $x64Installer = New-TestPackage -Destination (Join-Path $packageRoot 'x64') -Manifest $x64Manifest -Artifacts $x64Artifacts
}

$results = [ordered]@{}
$nativeParent = Join-Path $installRoot 'native-update'
[IO.Directory]::CreateDirectory($nativeParent) | Out-Null
$nativeState = Get-InstallState $nativeParent

$results.nativeInstall = Invoke-TestInstaller $armInstaller 'win-arm64' $nativeParent
Assert-Exit $results.nativeInstall 0 'native install'
$nativeMarker = Get-Marker $nativeState.installRoot
if ($nativeMarker.runtime -ne 'win-arm64' -or $nativeMarker.buildId -ne $armPayload.build.buildId) { throw 'Native install marker mismatch.' }
Assert-RequiredMachine $nativeState.installRoot 0xAA64
$userFile = Join-Path $nativeState.installRoot 'owner-file.txt'
[IO.File]::WriteAllText($userFile, 'preserve')

$results.nativeUpdate1 = Invoke-TestInstaller $armInstaller 'win-arm64' $nativeParent
Assert-Exit $results.nativeUpdate1 0 'native update 1'
$results.nativeUpdate2 = Invoke-TestInstaller $armInstaller 'win-arm64' $nativeParent
Assert-Exit $results.nativeUpdate2 0 'native update 2'
if ((Get-Content -LiteralPath $userFile -Raw) -ne 'preserve') { throw 'User file was not preserved.' }

[IO.Directory]::CreateDirectory($nativeState.stateRoot) | Out-Null
$leasePath = Join-Path $nativeState.stateRoot 'lease-arm64-acceptance.lock'
$lease = [IO.File]::Open($leasePath, 'Create', 'ReadWrite', 'Read')
try {
    $results.busyReject = Invoke-TestInstaller $armInstaller 'win-arm64' $nativeParent
    Assert-Exit $results.busyReject 8 'busy rejection'
} finally {
    $lease.Dispose()
    Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue
}

$beforeLauncher = (Get-FileHash -LiteralPath (Join-Path $nativeState.installRoot 'PdfCompressor.App.exe') -Algorithm SHA256).Hash
$beforeMarker = (Get-FileHash -LiteralPath (Join-Path $nativeState.installRoot '.pdf-compressor-install.json') -Algorithm SHA256).Hash
$results.rollback = Invoke-TestInstaller $armInstaller 'win-arm64' $nativeParent -FailAfterFiles 3
Assert-Exit $results.rollback 1 'injected rollback'
if ((Get-FileHash -LiteralPath (Join-Path $nativeState.installRoot 'PdfCompressor.App.exe') -Algorithm SHA256).Hash -ne $beforeLauncher) { throw 'Launcher was not restored after rollback.' }
if ((Get-FileHash -LiteralPath (Join-Path $nativeState.installRoot '.pdf-compressor-install.json') -Algorithm SHA256).Hash -ne $beforeMarker) { throw 'Marker was not restored after rollback.' }

$switchState = $null
if (-not $Arm64Only) {
    $switchParent = Join-Path $installRoot 'runtime-switch'
    [IO.Directory]::CreateDirectory($switchParent) | Out-Null
    $switchState = Get-InstallState $switchParent
    $switchUserFile = Join-Path $switchState.installRoot 'owner-file.txt'

    $results.x64Install = Invoke-TestInstaller $x64Installer 'win-x64' $switchParent
    Assert-Exit $results.x64Install 0 'x64 install'
    Assert-RequiredMachine $switchState.installRoot 0x8664
    [IO.File]::WriteAllText($switchUserFile, 'preserve')

    $results.arm64SwitchReject = Invoke-TestInstaller $armInstaller 'win-arm64' $switchParent
    Assert-Exit $results.arm64SwitchReject 12 'x64 to ARM64 default rejection'
    if ((Get-Marker $switchState.installRoot).runtime -ne 'win-x64') { throw 'Rejected switch changed the marker.' }

    $results.arm64Switch = Invoke-TestInstaller $armInstaller 'win-arm64' $switchParent -AllowRuntimeSwitch
    Assert-Exit $results.arm64Switch 0 'x64 to ARM64 switch'
    if ((Get-Marker $switchState.installRoot).runtime -ne 'win-arm64') { throw 'ARM64 switch marker mismatch.' }
    Assert-RequiredMachine $switchState.installRoot 0xAA64
    if ((Get-Content -LiteralPath $switchUserFile -Raw) -ne 'preserve') { throw 'User file was lost during ARM64 switch.' }

    $results.x64SwitchReject = Invoke-TestInstaller $x64Installer 'win-x64' $switchParent
    Assert-Exit $results.x64SwitchReject 12 'ARM64 to x64 default rejection'
    $results.x64Switch = Invoke-TestInstaller $x64Installer 'win-x64' $switchParent -AllowRuntimeSwitch
    Assert-Exit $results.x64Switch 0 'ARM64 to x64 switch'
    if ((Get-Marker $switchState.installRoot).runtime -ne 'win-x64') { throw 'x64 switch marker mismatch.' }
    Assert-RequiredMachine $switchState.installRoot 0x8664
    if ((Get-Content -LiteralPath $switchUserFile -Raw) -ne 'preserve') { throw 'User file was lost during x64 switch.' }
}

$receipt = [ordered]@{
    schemaVersion = 1
    status = 'passed'
    executedAt = [DateTimeOffset]::Now.ToString('o')
    hostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    arm64Candidate = $candidateFull
    arm64BuildId = $armPayload.build.buildId
    arm64PayloadSha256 = $armPayload.sha256
    canonicalX64PayloadSha256 = if ($null -ne $x64Payload) { $x64Payload.sha256 } else { $null }
    cases = [ordered]@{
        nativeInstall = $results.nativeInstall.exitCode
        nativeUpdate1 = $results.nativeUpdate1.exitCode
        nativeUpdate2 = $results.nativeUpdate2.exitCode
        busyReject = $results.busyReject.exitCode
        injectedRollback = $results.rollback.exitCode
        x64Install = if ($results.Contains('x64Install')) { $results.x64Install.exitCode } else { $null }
        x64ToArm64Reject = if ($results.Contains('arm64SwitchReject')) { $results.arm64SwitchReject.exitCode } else { $null }
        x64ToArm64Switch = if ($results.Contains('arm64Switch')) { $results.arm64Switch.exitCode } else { $null }
        arm64ToX64Reject = if ($results.Contains('x64SwitchReject')) { $results.x64SwitchReject.exitCode } else { $null }
        arm64ToX64Switch = if ($results.Contains('x64Switch')) { $results.x64Switch.exitCode } else { $null }
    }
    userFilesPreserved = $true
    requiredPeMachinesVerified = if ($Arm64Only) { @('0xAA64') } else { @('0xAA64', '0x8664') }
    nativeBackupCount = @(Get-ChildItem -LiteralPath $nativeState.backupRoot -Directory -Filter 'previous-*' -ErrorAction SilentlyContinue).Count
    switchBackupCount = if ($null -ne $switchState) { @(Get-ChildItem -LiteralPath $switchState.backupRoot -Directory -Filter 'previous-*' -ErrorAction SilentlyContinue).Count } else { 0 }
    arm64Only = [bool]$Arm64Only
    artifactsRetained = $true
    canonicalModified = $false
}
$receiptPath = Join-Path $outputRootFull 'acceptance-receipt.json'
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 8
$global:LASTEXITCODE = 0
