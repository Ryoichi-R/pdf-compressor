# Copyright (c) 2026 Ryoichi-R
# Licensed under the GNU Affero General Public License version 3 or later.
# See LICENSE in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [Parameter(Mandatory)][string]$PowerShellRoot,
    [Parameter(Mandatory)][string]$QpdfRoot,
    [Parameter(Mandatory)][string]$PopplerRoot,
    [Parameter(Mandatory)][string]$GhostscriptRoot,
    [string]$CandidateRoot,
    [switch]$KeepFailedStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Build-PayloadCandidate.ps1') @PSBoundParameters
return
