[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$InstallRoot = $env:PDF_COMPRESSOR_INSTALL_ROOT,
    [string]$CuratedSignedPdf,
    [switch]$ExcludeEncrypted,
    [switch]$Force
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'support\New-SyntheticPdf.ps1')

if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw 'InstallRoot is required. Set PDF_COMPRESSOR_INSTALL_ROOT or pass -InstallRoot.' }
$installRootFull = [IO.Path]::GetFullPath($InstallRoot)
$qpdf = Join-Path $installRootFull 'runtime\tools\qpdf.exe'
if (-not (Test-Path -LiteralPath $qpdf -PathType Leaf)) { throw "Bundled qpdf is missing: $qpdf" }

if ([string]::IsNullOrWhiteSpace($CuratedSignedPdf)) {
    $CuratedSignedPdf = Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures\pdf\curated\dss-pdf-signed-original.pdf'
}
if (-not (Test-Path -LiteralPath $CuratedSignedPdf -PathType Leaf)) { throw "Curated signed PDF is missing: $CuratedSignedPdf" }

$corpusRoot = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $corpusRoot) {
    if (-not $Force) { throw "Corpus directory already exists: $corpusRoot" }
    Remove-Item -LiteralPath $corpusRoot -Recurse -Force
}
[IO.Directory]::CreateDirectory($corpusRoot) | Out-Null

function Invoke-BundledQpdf([string[]]$QpdfArguments) {
    $output = & $qpdf @QpdfArguments 2>&1
    # qpdf exit code 3 means warnings only; the fixture is still usable.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) {
        throw ("qpdf failed (exit {0}): {1}" -f $LASTEXITCODE, ($output -join ' '))
    }
}

$staging = Join-Path ([IO.Path]::GetTempPath()) ('arm64-benefit-corpus-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($staging) | Out-Null
try {
    # text-vector: multi-page vector content only.
    New-SyntheticPdf -OutputPath (Join-Path $corpusRoot 'text-vector.pdf') -PageCount 3 -TargetBytes 1500000 | Out-Null

    # high-dpi-scan: single large grayscale raster page (scan proxy).
    New-SyntheticPdf -OutputPath (Join-Path $corpusRoot 'high-dpi-scan.pdf') -PageCount 1 `
        -IncludeRasterImage -RasterWidth 1600 -RasterHeight 2000 | Out-Null

    # mixed-content: text, raster image, and interactive structures on the same document.
    New-SyntheticPdf -OutputPath (Join-Path $corpusRoot 'mixed-content.pdf') -PageCount 2 -TargetBytes 1000000 `
        -IncludeRasterImage -RasterWidth 800 -RasterHeight 1000 -IncludeAcroForm -IncludeAttachmentsOutlinesLinks | Out-Null

    # already-optimized: qpdf object streams applied twice so a further pass has no effect.
    $plainOptimized = Join-Path $staging 'already-optimized-plain.pdf'
    $optimizedOnce = Join-Path $staging 'already-optimized-once.pdf'
    New-SyntheticPdf -OutputPath $plainOptimized -PageCount 2 -TargetBytes 900000 | Out-Null
    Invoke-BundledQpdf @('--object-streams=generate', '--deterministic-id', '--', $plainOptimized, $optimizedOnce)
    Invoke-BundledQpdf @('--object-streams=generate', '--deterministic-id', '--', $optimizedOnce, (Join-Path $corpusRoot 'already-optimized.pdf'))

    # encrypted: AES-256 with a static IV/ID so the corpus digest stays reproducible.
    # The pipeline rejects encrypted input by policy, which makes compress.ps1 exit
    # non-zero, so -ExcludeEncrypted produces a corpus that can reach a clean run.
    if (-not $ExcludeEncrypted) {
        $encryptedPlain = Join-Path $staging 'encrypted-plain.pdf'
        New-SyntheticPdf -OutputPath $encryptedPlain -PageCount 1 -TargetBytes 400000 | Out-Null
        Invoke-BundledQpdf @('--encrypt', '--user-password=fixture-user', '--owner-password=fixture-owner', '--bits=256', '--',
            '--static-id', '--static-aes-iv', $encryptedPlain, (Join-Path $corpusRoot 'encrypted.pdf'))
    }

    # signed: curated DSS fixture, copied byte-for-byte.
    Copy-Item -LiteralPath $CuratedSignedPdf -Destination (Join-Path $corpusRoot 'signed.pdf') -Force
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}

$files = @(Get-ChildItem -LiteralPath $corpusRoot -Recurse -File -Filter '*.pdf' | Sort-Object FullName)
$lines = @($files | ForEach-Object {
    '{0}|{1}|{2}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToUpperInvariant(), $_.Length
})
$bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
$sha = [Security.Cryptography.SHA256]::Create()
try { $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '') } finally { $sha.Dispose() }

return [pscustomobject]@{
    path = $corpusRoot
    fileCount = $files.Count
    totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
    sha256 = $digest
    files = @($files | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            length = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        }
    })
}
