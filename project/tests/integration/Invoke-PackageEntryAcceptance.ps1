[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AcceptanceRoot,
    [Parameter(Mandatory)][string]$Arm64Candidate,
    [switch]$ForwardOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..')).TrimEnd('\')
$acceptanceRootFull = [IO.Path]::GetFullPath($AcceptanceRoot).TrimEnd('\')
$candidateFull = [IO.Path]::GetFullPath($Arm64Candidate).TrimEnd('\')
foreach ($path in @($acceptanceRootFull, $candidateFull)) {
    if (-not $path.StartsWith($repositoryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Inputs must remain under the repository root.'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Directory not found: $path" }
}

$armPackage = Join-Path $acceptanceRootFull 'packages\arm64'
$x64Package = Join-Path $acceptanceRootFull 'packages\x64'
$installParent = Join-Path $acceptanceRootFull 'installs\runtime-switch'
$installRoot = Join-Path $installParent 'PDF Compressor'
$markerPath = Join-Path $installRoot '.pdf-compressor-install.json'
$armEntry = Join-Path $armPackage 'entry-arm64-only.bat'
$x64Entry = Join-Path $x64Package 'entry-x64-only.bat'
Copy-Item -LiteralPath (Join-Path $candidateFull 'profiles\arm64-only\root-entry.bat') -Destination $armEntry
Copy-Item -LiteralPath (Join-Path $projectRoot 'installer\assets\root-entry-x64-only.bat') -Destination $x64Entry

function Get-InstalledRuntime {
    (Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json).runtime
}

function Invoke-Entry([string]$Entry,[string]$InputText) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $env:ComSpec
    $start.Arguments = "/d /c `"`"$Entry`" `"$installParent`"`""
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill($true) } catch {}
        throw "Package entry timed out: $Entry"
    }
    [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $stdout; stderr = $stderr }
}

function Assert-Case([object]$Result,[int]$ExpectedExit,[string]$ExpectedRuntime,[string]$Name) {
    if ($Result.exitCode -ne $ExpectedExit) {
        throw "$Name returned exit $($Result.exitCode), expected $ExpectedExit. stdout=$($Result.stdout) stderr=$($Result.stderr)"
    }
    $runtime = Get-InstalledRuntime
    if ($runtime -ne $ExpectedRuntime) { throw "$Name left runtime $runtime, expected $ExpectedRuntime" }
}

if ((Get-InstalledRuntime) -ne 'win-x64') { throw 'The retained runtime-switch fixture must start at win-x64.' }
$userFile = Join-Path $installRoot 'owner-file.txt'

$x64ToArm64Reject = Invoke-Entry $armEntry "N`r`n`r`n"
Assert-Case $x64ToArm64Reject 4 'win-x64' 'x64 to ARM64 prompt rejection'
$x64ToArm64Accept = Invoke-Entry $armEntry "Y`r`n"
Assert-Case $x64ToArm64Accept 0 'win-arm64' 'x64 to ARM64 prompt acceptance'
$arm64ToX64Reject = $null
$arm64ToX64Accept = $null
if (-not $ForwardOnly) {
    $arm64ToX64Reject = Invoke-Entry $x64Entry "N`r`n`r`n"
    Assert-Case $arm64ToX64Reject 4 'win-arm64' 'ARM64 to x64 prompt rejection'
    $arm64ToX64Accept = Invoke-Entry $x64Entry "Y`r`n"
    Assert-Case $arm64ToX64Accept 0 'win-x64' 'ARM64 to x64 prompt acceptance'
}
if ((Get-Content -LiteralPath $userFile -Raw) -ne 'preserve') { throw 'User file was not preserved across package entry switches.' }

$receipt = [ordered]@{
    schemaVersion = 1
    status = 'passed'
    executedAt = [DateTimeOffset]::Now.ToString('o')
    hostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    cases = [ordered]@{
        x64ToArm64Reject = $x64ToArm64Reject.exitCode
        x64ToArm64Accept = $x64ToArm64Accept.exitCode
        arm64ToX64Reject = if ($null -ne $arm64ToX64Reject) { $arm64ToX64Reject.exitCode } else { $null }
        arm64ToX64Accept = if ($null -ne $arm64ToX64Accept) { $arm64ToX64Accept.exitCode } else { $null }
    }
    rejectionMessageObserved = (
        $x64ToArm64Reject.stdout -match 'Runtime switch cancelled' -and
        ($ForwardOnly -or $arm64ToX64Reject.stdout -match 'Runtime switch cancelled')
    )
    finalRuntime = Get-InstalledRuntime
    forwardOnly = [bool]$ForwardOnly
    userFilePreserved = $true
    canonicalModified = $false
}
if (-not $receipt.rejectionMessageObserved) { throw 'Expected package entry rejection message was not observed.' }
$receiptPath = Join-Path $acceptanceRootFull 'package-entry-receipt.json'
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 6
