Set-StrictMode -Version Latest

BeforeAll {
    $script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:ScriptPath = Join-Path $script:ProjectRoot 'installer\dependencies\Test-PopplerSourceSignature.ps1'

    # third-party-source/ は .gitignore 対象で fresh clone には含まれない。
    # 通常実行では理由を明示して Skip し、リリース検証・第三者ソース確認では
    # PDF_COMPRESSOR_REQUIRE_THIRD_PARTY_SOURCE=1 を指定して不在を Fail にする。
    $script:ArchivePath = Join-Path $script:ProjectRoot 'third-party-source\poppler-26.07.0.tar.xz'
    $script:ArchivePresent = Test-Path -LiteralPath $script:ArchivePath -PathType Leaf
    $script:RequireThirdPartySource = ($env:PDF_COMPRESSOR_REQUIRE_THIRD_PARTY_SOURCE -eq '1')

    function Assert-PopplerArchiveAvailable {
        if ($script:ArchivePresent) { return $true }
        if ($script:RequireThirdPartySource) {
            throw "[E_THIRD_PARTY_SOURCE_MISSING] 厳格モード (PDF_COMPRESSOR_REQUIRE_THIRD_PARTY_SOURCE=1) では第三者ソースの不在を許容しません: $script:ArchivePath"
        }
        Set-ItResult -Skipped -Because "third-party-source/poppler-26.07.0.tar.xz が存在しない（.gitignore 対象の再取得可能アーカイブ）。厳格に検証するには PDF_COMPRESSOR_REQUIRE_THIRD_PARTY_SOURCE=1 を設定する"
        return $false
    }
}

Describe 'Poppler source signature verification contract' -Tag 'WindowsOnly' {
    It 'verifies all pinned evidence and binds VALIDSIG to the expected fingerprint' {
        if (-not (Assert-PopplerArchiveAvailable)) { return }
        $result = & $script:ScriptPath
        $result.status | Should -Be 'verified'
        $result.signerFingerprint | Should -Be 'CA262C6C83DE4D2FB28A332A3A6A4DB839EAA6D7'
        $result.archiveSha256 | Should -Be '304832F48F8A47FDCA90C6B6D1F684E68F37C10C9A0726F345F4CA9DF4CA01E2'
    }

    It 'fails closed when the expected archive hash is wrong' {
        if (-not (Assert-PopplerArchiveAvailable)) { return }
        { & $script:ScriptPath -ExpectedArchiveSha256 ('0' * 64) } | Should -Throw '*SHA-256 mismatch*'
    }
}
