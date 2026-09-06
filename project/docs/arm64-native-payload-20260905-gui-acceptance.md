# ARM64 native payload GUI acceptance — 2026-09-05

## Result

Windows ARM64 native実機上で、修正版の非canonical `arm64-only` candidateを生成し、実PDFをGUIから選択して圧縮を完了した。GUIログは`status=ok`、`verification_status=verified`を記録し、bundled ARM64 qpdfによる再検証も成功した。

canonical payloadの変更・promotion、release、commit、push、公開は実施していない。

## Binding

- Workspace / Git root: `C:\coding\workspace-control`
- Plan: `C:\coding\workspace-control\plans\old\20260905_pdf-compressor-arm64-native-payload-plan.md`
- Plan SHA-256 at GUI execution: `C9C2F4F2C27113329C69617F9F4BFF9C320002325656422F0FBB14E27325A94C`
- Plan SHA-256 after status update: `26DA046AC332D2BE7173DC347AC1DD01A066435A0D93FF88A9B6468949F24C46`
- Candidate: `pdf-compressor/project/installer/candidates/20260905T1445JST-arm64-gui-fix-2`
- Build ID: `pdfc-1.1.0-win-arm64-4cb546f866125721`
- Source digest: `2362C8EC3663564C16B0CB8545F522813901D7B82F7CADE86562C26FC02F2E85`
- Dependency digest: `00B0493B91503C92D34592CE3BF96CAC902C66B3E14D21408E175EDD84F4ED79`
- Payload tree digest: `0667F2588D88F81767D421CF24CEABCCFA8D872B06273233188871FE72441845`
- Manifest SHA-256: `0CBF88DDB179A4E6C46C806D8B52930A154420703F5B4DC65881CE39CA850DE8`
- ARM64 payload SHA-256: `93D3BAF7A9C506752EB0BA44E0C93BA8E31430ADDB2F38FFC457B811FE01BF3B`
- Corresponding-source SHA-256: `2790DE6D99F2077848AE93EB80EF68F947D3C3B72FDF3355EB012EA42E506267`
- Host OS / process architecture: `Arm64` / `Arm64`

## Implemented fixes

1. GUIの`verification`イベントで空の`reasons`が`$null`へ潰れ、StrictMode下の`.Count`参照が例外になる問題を修正した。
2. `Test-Payload.ps1 -RunDiagnostics`がfresh展開先の`_work`を作成せずlauncher diagnosticsを失敗させる問題を修正した。
3. 両経路へ回帰contractを追加した。

## GUI acceptance

- Input: `gui-compressible.pdf`、5,338,240 bytes、SHA-256 `4CCD898F5277A8DBBE2AA1DF1FB81AE763181279B8FC247C8D81B0C04785C825`
- Output: `gui-compressible.compressed.pdf`、6,869 bytes、SHA-256 `227AE63700E944511E68BBCA1F14357D477149A477437C1200916844205D41A5`
- Size reduction: 5,331,371 bytes / 99.8713%
- Input/output pages: 3 / 3
- GUI log: `status=ok`、`strategy_id=qpdf-lossless`、`tool=qpdf`、`verification_status=verified`、reasons 0件
- Bundled `qpdf --check`: exit 0、syntax/stream encoding errorなし
- Bundled `pdfinfo`: input/outputともexit 0、3ページ、letter、rotation 0、unencrypted
- Raw receipt: `_work/gui-acceptance-20260905T1445JST-gui-fix-2/gui-acceptance-receipt.json`

## Validation

| Validation                               | Result                                                                               |
| ---------------------------------------- | ------------------------------------------------------------------------------------ |
| Targeted unit                            | 64 pass / 0 fail / 3 skip                                                            |
| Full unit                                | 416 pass / 0 fail / 4 skip                                                           |
| Coverage                                 | 90.65%（3,228 covered / 333 missed、target 90%）                                     |
| Candidate fresh extraction + diagnostics | pass、build ID一致                                                                   |
| Bundled ARM64 E2E                        | 18 pass / 0 fail / 0 skip                                                            |
| ARM64-only installer matrix              | pass。install 0、update 0/0、busy 8、injected rollback 1、user file保持、PE `0xAA64` |
| PowerShell parser                        | 変更4ファイル、syntax error 0                                                        |

ARM64-only installer matrixの最初の実行は受入ルートが長く、PowerShell moduleの深いパスでWindows path-length errorになった。失敗領域を保持し、短いfresh pathで再実行してpassした。receipt SHA-256は`9E59D59C8E2CEC00F5861709C09307AC1FBE95CB603FCA94D14BB98340596B4B`。

Project format checkは既存19ファイルの形式差分によりexit 3。変更4ファイルのPaths checkは変更件数0だったが、要求版PSScriptAnalyzer 1.25.0を解決できずBLOCKED。Fast lintも同じtoolchain理由でBLOCKEDとして記録した。無関係なファイルは整形していない。

## Remaining boundaries

- 独立native x64 host回帰とdual-runtime release compositionは未完了。
- 署名・配布判断・canonical promotion前後のx64 parity/rollbackは未完了。
- canonical promotion、release、commit、push、公開は未実施。
