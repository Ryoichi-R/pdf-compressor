# ARM64 native payload verification summary — 2026-09-05

> Superseded by `arm64-native-payload-20260905-final.md`. This file preserves the fail-closed checkpoint before external dependency retrieval was authorized.

## Status

`BLOCKED`: qpdf、Poppler、Ghostscript の Windows ARM64 native 再ビルドと機能確認は成功したが、ARM64 .NET runtime pack を取得できず candidate と manifest は未生成。既存 candidate、過去 receipt、x64 PC の結果は受入証拠に使用していない。

canonical payload の作成・変更・promotion、release、commit、push、公開は実施していない。

## Binding

- Workspace / Git root: `C:\coding\workspace-control`
- Project: `C:\coding\workspace-control\pdf-compressor\project`
- Plan: `C:\coding\workspace-control\plans\old\20260905_pdf-compressor-arm64-native-payload-plan.md`
- Plan SHA-256: `C9C2F4F2C27113329C69617F9F4BFF9C320002325656422F0FBB14E27325A94C`
- Project source inventory: 82 files、SHA-256 `3B10AE8E8B2324B8D56D6501CB240A0272585DB2E7E024F41E0CD7BA62393FE2`
- Run: 2026-09-05 13:08–13:46 JST
- Initial `git status --short`: clean

## Native host evidence

- OS: Microsoft Windows NT 10.0.26200.0
- OS architecture / process architecture: `Arm64` / `Arm64`
- `IsWow64Process2`: process machine `0x0000`、native machine `0xAA64`
- pwsh、Git、dotnet、CMake、Ninja、vcpkg、MSVC `cl.exe`: PE `0xAA64`
- MSVC: 14.44.35207、HostARM64/arm64
- CMake 3.31.8 SHA-256: `4DCA17DC521E308D9EBB28B1D81C13ECE11AC9D612E12F3E05F5D1CB52BF8B20`
- Ninja 1.13.2 SHA-256: `7F519AFD93CD1D1DCE67C9644990B5D3B40B458E547CB39DF608D8F352A6AD79`
- vcpkg executable SHA-256: `5E8D7ACD0F3049411AD1EACD3AF2A946014ED430C27010E384EE1289A8E98CBC`
- x64 の `gpgv.exe` は署名検証専用で bundled payload には含めていない。

## Verified inputs

| Input                              | SHA-256                                                            | Verification                             |
| ---------------------------------- | ------------------------------------------------------------------ | ---------------------------------------- |
| Poppler 26.07.0 source             | `304832F48F8A47FDCA90C6B6D1F684E68F37C10C9A0726F345F4CA9DF4CA01E2` | fixed hash match、signature verified     |
| Poppler signature                  | `AAFA340DBBEE102347EAA790B653E72F64C2A22F45E45ACE4953495A6F84BB8D` | signer match                             |
| Poppler signer fingerprint         | `CA262C6C83DE4D2FB28A332A3A6A4DB839EAA6D7`                         | plan value match                         |
| qpdf 12.3.2 source                 | `6CBA2F9F2CD887D905FAEB99E0E51A307B217920D1BBF3E9CFBB2E8178A2DEDA` | build contract match                     |
| Ghostscript 10.07.1 source         | `1CDB766DE8DB8F1E589C817F09C5855EA5F65DFC8540E465A69AC14C18416025` | build contract match                     |
| PowerShell 7.6.3 win-arm64 archive | `2ECE90557C370BB5EE03275EF41F2A49E26EA85DEFCF2052ACA32C20DADB62C2` | fixed hash match、`pwsh.exe` PE `0xAA64` |

Poppler は固定ハッシュと署名を今回再検証した。固定 archive は共有ワークスペースに存在した同一バイト列を今回ハッシュ検証して使用したため、再ダウンロード済みとは扱わない。ARM64 証拠は今回生成した build receipt に限定した。

## Current-run native outputs

Raw receipts and roots are under ignored `.tmp/pdfc-arm64-20260905T0415Z/`.

| Runtime             | Tree SHA-256                                                       | Architecture            | Functional result        | Receipt SHA-256                                                    |
| ------------------- | ------------------------------------------------------------------ | ----------------------- | ------------------------ | ------------------------------------------------------------------ |
| PowerShell 7.6.3    | `498C1CF87149314E48345B4E5EADD58E6175F16E4786E246E7C7D1BD4E548976` | native executable ARM64 | version pass             | -                                                                  |
| qpdf 12.3.2         | `F40B020949795E8829090108A944C1DD876639E65DBB1F41CCC36C4FCB930B77` | 6/6 PE files `0xAA64`   | 2 pass / 0 fail / 0 skip | `4ABE8F334094E0F3B3A4F7AFD061BAEF62FCE7BFCD755CBFD9DA065628283163` |
| Poppler 26.07.0     | `8B3E9C25C5CD7074E02CD5F31392B07670A7D8B750088156C65CBA7EDE4FD9DD` | 20/20 PE files `0xAA64` | 4 pass / 0 fail / 0 skip | `4BEAC87A2AF53F37B3CFB89AE032BCCC444F71AF40F8ED1B66DE8FB678A4809F` |
| Ghostscript 10.07.1 | `6279A3FF6912ADED2325C8EBF92174B0C55962FBBBCE582605E02C4F64B23020` | 4/4 PE files `0xAA64`   | 2 pass / 0 fail / 0 skip | `9169B9D8D20EFB152303256922AF91C2341771748D0C8527579E3E695835F961` |

qpdf と Poppler は `VCPKG_BINARY_SOURCES=clear` で binary cache を無効化した。cache を使用した最初の qpdf 試行は証拠から除外し、上表は再ビルドした `qr2` の値。

## Candidate and validation

- Intended candidate: `installer/candidates/20260905T1325JST-arm64-native`
- Candidate / candidate SHA-256: not generated / N/A
- Manifest / manifest SHA-256: not generated / N/A
- Candidate target exists at stop: no
- Canonical payload exists at stop: no

| Validation                                                                       | Exit / counts                                       | Result                                                                                           |
| -------------------------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `scripts/check-module-toplevel.ps1`                                              | 0、50 modules、0 errors、7 existing legacy warnings | pass                                                                                             |
| `scripts/format.ps1 -Check -Scope Project -ProjectPath pdf-compressor/project`   | 1、145 total、7 would-change、1 tool failure        | blocked: PSScriptAnalyzer 1.25.0 absent and sandboxed dotnet-format access; check-only、no edits |
| `scripts/lint.ps1 -Mode Fast -Scope Project -ProjectPath pdf-compressor/project` | 1、0 pass / 0 fail / 1 not-run                      | blocked by format gate                                                                           |
| `_internal/run-tests.ps1 -Suite Unit -CodeCoverage`                              | 1、0 collected                                      | Pester 5+ absent; detected 3.4.0、coverage not generated                                         |
| performance                                                                      | 1 not-run                                           | candidate absent                                                                                 |
| installer / integration                                                          | 1 not-run                                           | candidate and manifest absent                                                                    |
| strict E2E bundled payload                                                       | 1 not-run                                           | current candidate cannot be bound to `PDF_COMPRESSOR_INSTALL_ROOT`                               |
| GUI acceptance                                                                   | 1 not-run                                           | candidate absent                                                                                 |

`Build-PayloadCandidate.ps1 -Runtime win-arm64` failed at launcher restore. The first attempt returned `NU1301` for blocked NuGet access. The local-cache-only attempt returned `NU1101` for missing `Microsoft.NET.ILLink.Tasks`, `Microsoft.NETCore.App.Runtime.win-arm64`, `Microsoft.WindowsDesktop.App.Runtime.win-arm64`, and `Microsoft.AspNetCore.App.Runtime.win-arm64`.

Reusing an existing candidate or prior receipt would violate the acceptance boundary, so the run stopped without claiming acceptance. Resume requires pinned ARM64 runtime packs and Pester 5.7.1 in an isolated workspace area, followed by a new candidate, manifest validation, installer/integration, strict bundled-payload E2E, and GUI acceptance.
