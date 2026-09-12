# Copyright (c) 2026 Ryoichi-Rice and contributors
# Licensed under the MIT License.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('x64-only', 'arm64-only', 'dual-runtime')][string]$Profile,
    [string]$OutputPath,
    [switch]$AsText
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$templateName = switch ($Profile) {
    'x64-only' { 'root-entry-x64-only.bat' }
    'arm64-only' { 'root-entry-arm64-only.bat' }
    'dual-runtime' { 'root-entry-dual-runtime.bat' }
}
$templatePath = Join-Path $PSScriptRoot ("assets\{0}" -f $templateName)
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Entry BAT template is missing: $templatePath" }
$content = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::ASCII)

if ($AsText) { $content; exit 0 }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'OutputPath is required unless -AsText is used.' }
$destination = [IO.Path]::GetFullPath($OutputPath)
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if ($destination -ne $projectRoot -and -not $destination.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must remain under the PDF Compressor project root: $destination"
}
[IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
[IO.File]::WriteAllText($destination, $content, [Text.Encoding]::ASCII)
[pscustomobject]@{ Profile = $Profile; OutputPath = $destination; Sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash }
