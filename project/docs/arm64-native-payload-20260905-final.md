# ARM64 native payload acceptance summary — 2026-09-05

## Result

Windows ARM64 native 実機上で新規 `arm64-only` candidateを生成し、candidateの全ファイルhash、ARM64 PE closure、launcher diagnostics、unit/coverage、strict bundled-payload E2E、ARM64-only installer matrix、性能測定、GUI first-paintを確認した。その後、対話GUIで発見した空配列処理bugを修正し、修正版candidateによる実PDFのGUI圧縮まで完了した。最新bindingは[GUI acceptance](arm64-native-payload-20260905-gui-acceptance.md)を参照。

canonical payloadの作成・変更・promotion、release、commit、push、公開は実施していない。既存candidate、過去receipt、x64 PCの結果は今回のARM64受入証拠に使用していない。

## Initial candidate binding

- Workspace / Git root: `C:\coding\workspace-control`
- Project: `C:\coding\workspace-control\pdf-compressor\project`
- Plan: `C:\coding\workspace-control\plans\old\20260905_pdf-compressor-arm64-native-payload-plan.md`
- Plan SHA-256: `C9C2F4F2C27113329C69617F9F4BFF9C320002325656422F0FBB14E27325A94C`
- Candidate: `pdf-compressor/project/installer/candidates/20260905T1416JST-arm64-native`
- Build ID: `pdfc-1.1.0-win-arm64-590af5150af8294b`
- Runtime / profile: `win-arm64` / `arm64-only`
- Candidate source digest: `975DD163A18D636D6F423C4F9136188752DBFCD669BB1B4276695E06B2E2CC43`
- Dependency digest: `00B0493B91503C92D34592CE3BF96CAC902C66B3E14D21408E175EDD84F4ED79`
- Payload tree digest: `072DBDFCBD57D79ACBD716413E8E675AC3BA221238E2B09046542DB0261A90A7`
- Payload inventory: 1,589 files

| Candidate artifact             |      Length | SHA-256                                                            |
| ------------------------------ | ----------: | ------------------------------------------------------------------ |
| `pdf-compressor-win-arm64.zip` | 184,251,747 | `54DE5A512A7AE1811404F5281A4C3F43C95D58DB6F5D26F64523F09DA19696FF` |
| `payload-manifest.json`        |     333,463 | `92AAC7AAAA9CAB0EFE46447901BB5E050383E45FAFC036C56D3FC6A7BDAA4EDA` |
| `build-receipt.json`           |       1,069 | `AF90CAF888EE1B6FF61FF5693003CA5C688DA58021C322423353A97EC4AE734D` |
| corresponding-source ZIP       |  91,681,935 | `FDFCB2E1E2479C2D7A9A6189D2F991A951AF9FEE068C8AFD8491489A095365F8` |

## Native host and toolchain

- OS: Microsoft Windows NT 10.0.26200.0
- OS architecture / process architecture: `Arm64` / `Arm64`
- `IsWow64Process2`: process machine `0x0000`、native machine `0xAA64`（WOW64ではない）
- pwsh、Git、dotnet、CMake、Ninja、vcpkg、MSVC `cl.exe`: PE `0xAA64`
- MSVC 14.44.35207、HostARM64/arm64、compiler 19.44.35228.0
- CMake 3.31.8 SHA-256: `4DCA17DC521E308D9EBB28B1D81C13ECE11AC9D612E12F3E05F5D1CB52BF8B20`
- Ninja 1.13.2 SHA-256: `7F519AFD93CD1D1DCE67C9644990B5D3B40B458E547CB39DF608D8F352A6AD79`
- vcpkg executable SHA-256: `5E8D7ACD0F3049411AD1EACD3AF2A946014ED430C27010E384EE1289A8E98CBC`
- .NET SDK: 10.0.204
- Pester 5.7.1 manifest SHA-256: `C6DCE1CDD85A9236A9A628DCAAF3E6F07B0AC4173FB25F620FA466F4402EC341`
- PSScriptAnalyzer 1.25.0 manifest SHA-256: `2B219F688BCDD67101040F845E530B22907D39BBF49089B4B5B2AFABA7996791`
- x64 `gpgv.exe`は署名検証専用で、payloadには含めていない。

## Dependency evidence

| Dependency                 | Source SHA-256 / signature                                                 | Current-run output                                                      | ARM64 verification                     |
| -------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------- | -------------------------------------- |
| PowerShell 7.6.3 win-arm64 | archive `2ECE90557C370BB5EE03275EF41F2A49E26EA85DEFCF2052ACA32C20DADB62C2` | tree `498C1CF87149314E48345B4E5EADD58E6175F16E4786E246E7C7D1BD4E548976` | `pwsh.exe` PE `0xAA64`、version pass   |
| qpdf 12.3.2                | `6CBA2F9F2CD887D905FAEB99E0E51A307B217920D1BBF3E9CFBB2E8178A2DEDA`         | tree `F40B020949795E8829090108A944C1DD876639E65DBB1F41CCC36C4FCB930B77` | PE 6/6 ARM64、source/transform 2 pass  |
| Poppler 26.07.0            | `304832F48F8A47FDCA90C6B6D1F684E68F37C10C9A0726F345F4CA9DF4CA01E2`         | tree `8B3E9C25C5CD7074E02CD5F31392B07670A7D8B750088156C65CBA7EDE4FD9DD` | PE 20/20 ARM64、4 utility tests pass   |
| Ghostscript 10.07.1        | `1CDB766DE8DB8F1E589C817F09C5855EA5F65DFC8540E465A69AC14C18416025`         | tree `6279A3FF6912ADED2325C8EBF92174B0C55962FBBBCE582605E02C4F64B23020` | PE 4/4 ARM64、pdfwrite/pdfimage24 pass |

Poppler signature SHA-256は `AAFA340DBBEE102347EAA790B653E72F64C2A22F45E45ACE4953495A6F84BB8D`、検証結果は `verified`、署名者fingerprintは計画値 `CA262C6C83DE4D2FB28A332A3A6A4DB839EAA6D7` と一致した。qpdfとPopplerは `VCPKG_BINARY_SOURCES=clear` でbinary cacheを無効化して今回ビルドした。

## Initial validation

| Validation                              | Command / binding                                                        | Exit | Result                                                                                                                                                         |
| --------------------------------------- | ------------------------------------------------------------------------ | ---: | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Candidate build and embedded validation | `Build-PayloadCandidate.ps1 -Runtime win-arm64`                          |    0 | schema v3、全hash、1,589-file tree、PE closure、launcher build ID/diagnostics pass                                                                             |
| Independent extraction                  | `Test-Payload.ps1 -RunDiagnostics`、空の`final-candidate-install`        |    0 | `Valid=true`、build ID一致                                                                                                                                     |
| Unit + coverage                         | `_internal/run-tests.ps1 -Suite Unit -CodeCoverage`、Pester 5.7.1        |    0 | 415 pass / 0 fail / 4 skip、90.65%（3,228 covered / 333 missed、target 90%）                                                                                   |
| Strict E2E                              | `PDF_COMPRESSOR_INSTALL_ROOT=final-candidate-install`、host fallback無効 |    0 | 18 pass / 0 fail / 0 skip                                                                                                                                      |
| ARM64 installer acceptance              | `Invoke-Arm64InstallerAcceptance.ps1 -Arm64Only`                         |    0 | native install 0、update 0/0、busy reject 8、injected rollback 1（期待値）、user file保持、PE `0xAA64`                                                         |
| Performance                             | same 5-file approved corpus、warm-up 1、5 trials                         |    0 | 5,642 / 5,682 / 5,680 / 5,601 / 5,596 ms、mean 5,640.2 ms、全trial measurable exit 6                                                                           |
| GUI first-paint                         | final candidate launcher、実画面起動                                     |    0 | script-entered、controls-created、events-wired、`form-shown-event`、正常終了、trace SHA-256 `3C08392CE4A05DD73DAB628EDD31F0788A80457CB20EA4CE45396B0FDC94423B` |

- Coverage receipt: `pdf-compressor/project/coverage/coverage.xml`、SHA-256 `DEA6C4450AAFA69447A69F517839B4B83E7BED6342F0CBCAE02AA74DD2539EF3`
- Installer acceptance receipt: `.tmp/pdfc-arm64-20260905T0415Z/final-arm64-installer-acceptance/acceptance-receipt.json`、SHA-256 `636422B38EC4D55DEC2841914BFF695F34E24D3625C14FCF18E770DB427BE1D5`
- Performance receipt: `.tmp/pdfc-arm64-20260905T0415Z/final-performance-arm64.json`、SHA-256 `C605F656FFFCFE4616A9656430A80868608E425EC7F2EA99CECD67ADD2034F55`
- Corpus SHA-256: `DF964C7E5DB9B97BD316571671E501D0328F19FA6CE40641B7D77DBF4ED99F5C`

正式`-Suite Integration`の既存4件はcanonical `installer/payload`を固定参照するため、canonical不在の今回境界では1 pass / 3 failだった。これをcandidate証拠へ読み替えず、candidate専用のARM64-only installer matrixを追加して上表の5ケースを実行した。

## Implemented fixes

1. `Build-PayloadCandidate.ps1`: .NET SDKがinformational versionへGit revisionを自動付加し、manifest build IDと不一致になる問題を `IncludeSourceRevisionInInformationalVersion=false` で修正。
2. `installer_contract.Tests.ps1`: launcher informational versionとmanifest build IDの同一性contractを追加。
3. `Invoke-Arm64InstallerAcceptance.ps1`: canonical x64 payloadを変更・要求せずcandidate単独を検証する `-Arm64Only` を追加。
4. 同acceptance script: 注入rollbackの期待exit 1がスクリプト全体の成功exitへ残る問題を修正。

## Remaining boundaries

- 独立native x64 host回帰とx64↔ARM64 runtime-switch行列は、このARM64-only依頼では未実施。
- 性能receipt単体のthreshold fieldはharness仕様により`not-evaluated`。今回のnative平均は記録したが、過去のx64値を今回の実機証拠として再利用していない。
- PDF選択・実行ボタン・完了確認を含む対話GUI受入は、修正版candidateで完了した。hashと出力検証は[GUI acceptance](arm64-native-payload-20260905-gui-acceptance.md)に記録した。
- canonical promotion、release、commit、push、公開は未実施。
