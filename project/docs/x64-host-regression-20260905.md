# x64 host regression — 2026-09-05

## Result

ARM64 native payload work was resumed on the independent Windows x64 host
private development workspace. The reverse runtime-switch path in the x64-only
entry profile was corrected so the second installer invocation captures the
dynamic `%ERRORLEVEL%` inside the parenthesized batch block. The shipped root
entry, x64-only template, and package entry remain byte-identical after the
correction.

No canonical payload, ARM64 candidate, release, commit, push, or publication
was performed.

The sections through `Read-only ACL acceptance` below preserve the earlier
pre-B14 regression record. Their candidate IDs and receipt names are
historical; the current candidate and superseding evidence are recorded in
`B14 source-header candidate revalidation` near the end of this document.

## Historical pre-B14 record

## Host binding

- Git revision at test start: pre-separation private-workspace revision (not part of standalone history)
- OS / process architecture: `X64` / `X64`
- `PROCESSOR_ARCHITECTURE`: `AMD64`
- .NET SDK: `10.0.204`
- Pester: `5.7.1`

## Change and contract

- `installer/assets/root-entry.bat`
- `installer/assets/root-entry-x64-only.bat`
- `ここから開始 - PDF Compressorを導入・更新.bat`
- `tests/unit/installer_contract.Tests.ps1`

The runtime-switch contract now covers all four package profiles and requires
`call set "RC=%%ERRORLEVEL%%"` after the `-AllowRuntimeSwitch` invocation.

## Validation

| Validation                         | Result                                          |
| ---------------------------------- | ----------------------------------------------- |
| Installer contract                 | 37 passed / 0 failed / 3 skipped                |
| Full Unit                          | 416 passed / 0 failed / 4 skipped               |
| Coverage                           | 90.65% (3,228 covered / 333 missed; target 90%) |
| Strict E2E                         | 18 passed / 0 failed / 0 skipped                |
| Canonical-path Integration         | 1 passed / 3 failed                             |
| Isolated x64 candidate Integration | 4 passed / 0 failed                             |

The three canonical-path Integration failures are fail-closed because this
GitHub clone does not contain the ignored `installer/payload/payload-manifest.json`.
The active canonical x64 payload was not substituted with a candidate.

To continue the implementation without changing canonical state, an isolated
acceptance project was assembled under `installer/_work/acceptance-project`
from the candidate below. Its four Integration cases (install, real-PDF CLI
compression, update/user-file preservation, active-lease rejection, missing
managed-file repair, and injected rollback) all passed.

Candidate binding:

- build ID: `pdfc-1.1.0-win-x64-0b76086974cf3e3b`
- manifest SHA-256: `D8345B0F02FBACEF844A1DA370D3701E3FB37364E687C4C63B5EE0EC533DBD51`
- payload SHA-256 / length: `DACBBACC44995A2F84CF0D806B1FCF58C22B5EB2407F1B3A8147385FF6EE3B95` / `219706188`
- corresponding-source SHA-256 / length: `242DCA6F4428B14CB6C239CB0F37F06A5F110842639F9B583F756E4942FF2183` / `72011026`
- candidate tree digest: `4BB96E2C82D7CE927F7CE78894CF706A082E964A3D132EAC58622B56071BE1A1`

The candidate manifest validator and `Test-Payload.ps1 -RunDiagnostics` both
returned `Valid=True` / exit 0 under the permitted Windows host environment.
The candidate's `x64-only` root entry BAT was also exercised with a fresh
temporary install parent: exit 0, installed runtime `win-x64`, and the marker
recorded the candidate build ID above.

This is candidate-only evidence. It does not establish acceptance of the
missing canonical x64 baseline or dual-runtime package.

The project formatter/lint gate was later closed after the formatter scratch
root was moved under the workspace, generated `_work` boundaries were made
explicit, the malformed XML fixture was changed from `exclude` to
`check-only`, and `New-ImplementationSnapshot.ps1` received its missing
`Test-SecretFilePath` guard. Project Full lint then passed with 149 formatter
entries unchanged, 36/36 formatter contract tests, all required lint checks,
and classification `PASS`. Quality receipt:
`scratchpad/formatter/20260905T115527361Z-cbecb824/receipts/quality-receipt.json`.

The existing candidate source/dependency digest remains valid because the
candidate source inventory excludes `project/scripts`; no candidate payload or
canonical payload was modified by this remediation.

## Follow-up candidate acceptance

The current x64 candidate was staged under a shorter workspace path to avoid a
Windows PowerShell MAX_PATH false negative in the test harness. The isolated
installer acceptance passed fresh install, two updates, managed-file repair,
user-file preservation, active-lease rejection (exit 8), injected rollback
(exit 1), and capacity preflight (exit 10). The candidate-bound receipt is:

`result/pdf-compressor/x64-candidate-installer-acceptance-20260905.json`

The pure queue model scale check passed at 1/10/100/1000 items. The latest
cooperative-cancel run passed 5/5 without forced fallback; the maximum marker
to exit time was 3.90 seconds. These are process/model evidence only. GUI
first-paint, repaint at 100/125/150%, and interactive cancel control re-enable
remain open.

## CLI special-path acceptance

The current candidate was exercised through the product CLI against a short,
isolated validation root. Unicode, spaces, apostrophes, and a OneDrive-like
directory passed with CLI exit 0, qpdf check exit 0, and verification
`verified`. A near-MAX path also passed with an input length of 255 and an
output length of 258. The candidate-bound receipt is:

`result/pdf-compressor/special-path-acceptance-20260905.json`

The receipt records candidate build ID
`pdfc-1.1.0-win-x64-0b76086974cf3e3b`, payload SHA-256
`DACBBACC44995A2F84CF0D806B1FCF58C22B5EB2407F1B3A8147385FF6EE3B95`, and
tree digest
`4BB96E2C82D7CE927F7CE78894CF706A082E964A3D132EAC58622B56071BE1A1`.

## Representative real-PDF visual acceptance

The candidate compressed a representative A4 one-page PDF and produced a
valid output with CLI exit 0 and qpdf check exit 0. Both source and output
rendered successfully at 992 x 1404 pixels. The pixel difference was 890 of
1,392,768 pixels (0.0639%); visual review found no missing or overlapping
header/body/footer content, signature display, or green rule. The difference
was localized to signature glyphs and small footer glyph regions.

The candidate-bound receipt is:

`result/pdf-compressor/real-pdf-visual-acceptance-20260905.json`

This fixture contains PDF/A, AcroForm, annotations, and signature-related
features. The product recorded feature-loss warnings for those features, so
this is a visual-layout PASS with a preservation warning, not a full safety
or feature-preservation PASS. The full real-PDF safety/visual matrix remains
open.

## Safe-mode feature-preservation refusal

The same feature-rich fixture was then run in Safe mode with the lossy
strategy explicitly requested. The product reported `verification rejected`
and `validation rejected`, returned exit 1, and created no output. This is the
expected safety refusal for a PDF whose PDF/A, AcroForm, annotation, and
signature preservation cannot be guaranteed.

The candidate-bound receipt is:

`result/pdf-compressor/real-pdf-safety-acceptance-20260905.json`

The full real-PDF safety matrix remains open beyond this refusal case.

## GUI acceptance status

The candidate-bound `PdfCompressor.App.exe` exists in the validation root,
but Windows Computer Use could not obtain a target window because the
configured `sky` trusted RPC service was not available. No GUI behavior was
inferred from executable presence. First paint, repaint at 100/125/150%,
interactive cancel/UI idle, console-hidden launch, and close behavior remain
`NOT_RUN`.

The blocked acceptance receipt is:

`result/pdf-compressor/gui-acceptance-20260905.json`

## Generated fixture safety matrix

The candidate was then exercised against a six-file generated corpus with
seven explicit cases: vector text success, high-DPI scan success, mixed
content lossless success, mixed-content Ghostscript success with an AcroForm
warning, already-optimized no-effect, encrypted-input refusal, and signed /
feature-preservation refusal. All seven cases matched their expected exit
code and per-file status. Every produced output passed qpdf check.

The candidate-bound receipt is:

`result/pdf-compressor/real-pdf-safety-matrix-20260905.json`

This closes the generated fixture matrix only. External PDFs, a broader
real-world corpus, and complete PDF/A/AcroForm/signature preservation remain
open.
Read-only ACL denial is covered separately below. Installed GUI first
paint/repaint/UI idle and visual real-PDF acceptance remain separate manual
gates.

## Read-only ACL acceptance

The current candidate was exercised with an explicit write-deny ACL on a
temporary output directory. The CLI returned exit 1, reported access denied,
did not create the compressed output, and left the input SHA-256 unchanged.
The original ACL was restored and the temporary staging directory was removed
after the run. The candidate-bound receipt is:

`result/pdf-compressor/read-only-path-acceptance-20260905.json`

The receipt records candidate build ID
`pdfc-1.1.0-win-x64-0b76086974cf3e3b`, payload SHA-256
`DACBBACC44995A2F84CF0D806B1FCF58C22B5EB2407F1B3A8147385FF6EE3B95`, and
tree digest
`4BB96E2C82D7CE927F7CE78894CF706A082E964A3D132EAC58622B56071BE1A1`.

## B14 source-header candidate revalidation

The B14 source-header change touched 44 first-party files under `_internal/`,
`installer/`, and `src/PdfCompressor.Launcher/Program.cs`. The acceptance
receipt records before/after SHA-256 values, observed CRLF, BOM preservation,
and an exact backup tree. Generated payloads and third-party source were not
included.

The source digest changed, so the earlier candidate-bound receipts in the
historical sections above were not reused. A new isolated x64 candidate was
built and all affected automated and manual evidence was re-bound to it:

- candidate: `installer/_work/candidates/x64-host-20260905-b14`
- build ID: `pdfc-1.1.0-win-x64-c15d7e54a5c2960d`
- source digest: `2847DA47C0308D689C7844C4F64F805672DC77735A757DA1124C5124B8F877A8`
- dependency digest: `525344598397D128B7461029F8C87081D19C53FD0DFB2F9C0DA12A2FAD551FA9`
- payload SHA-256: `3B58DC0ADFDE00B014074849BFF139E9F8053FFCD64B8ADAB22C8134B6548C79`
- payload length: `219709213`
- candidate tree digest: `3F67BB7EA04CFA2F22E5D19A8FB4A585A32E09FBCE26AA16D1F5CCCD080E21E7`

The candidate manifest validator and `Test-Payload.ps1 -RunDiagnostics` both
returned `Valid=True` / exit 0. Unit tests passed 416/416 with 4 skips,
coverage remained 90.65%, strict E2E passed 18/18, candidate Integration
passed 4/4, and project formatter/lint remained PASS.

Current candidate-bound receipts are:

- `result/pdf-compressor/pdf-b14-header-acceptance-20260905.json`
- `result/pdf-compressor/x64-candidate-installer-acceptance-b14-20260905.json`
- `result/pdf-compressor/special-path-acceptance-b14-20260905.json`
- `result/pdf-compressor/read-only-path-acceptance-b14-20260905.json`
- `result/pdf-compressor/real-pdf-visual-acceptance-b14-20260905.json`
- `result/pdf-compressor/real-pdf-safety-acceptance-b14-20260905.json`
- `result/pdf-compressor/real-pdf-safety-matrix-b14-20260905.json`
- `result/pdf-compressor/gui-acceptance-b14-20260906.json`

The visual receipt records matching 1190 x 1684 renders, qpdf check exit 0,
and 74 changed pixels of 2,003,960 (0.003693%). It remains a feature-warning
result because PDF/A, AcroForm, annotation, and signature preservation is not
claimed. The generated six-file safety corpus is 7/7 expected outcomes with
warning/refusal/no-effect boundaries. The signed Safe default case is a
deliberate safety skip; with explicit `AllowSignedPdf`, feature-preservation
validation rejects the output and creates no file.

The packaged GUI was exercised through user-guided manual acceptance after the
Computer Use Windows-app surface remained unavailable. First paint, real
compression, cancel, hidden-console launch, and normal close passed. The first
cancel run exposed a stale `running` row and empty receipt file attribution;
the remediation candidate `pdfc-1.1.0-win-x64-a54f70a9c1686695` corrected the
row to `cancelled`, progress to `1 / 1 files`, re-enabled Run within eight
seconds, and wrote exactly one file-attributed aborted JSONL record. The final
run used the bounded forced fallback after the five-second cooperative grace
period. Evidence is recorded in
`result/pdf-compressor/gui-cancel-remediation-20260906.json`. Scale repaint
acceptance remains open.
The canonical payload remains absent and unmodified. No commit, push,
promotion, or publication was performed. The temporary B14 manual staging,
header backup, and application script were removed after the final local
cleanup check; the validated candidate remains preserved.

## Remaining boundaries

- canonical-path installer/update/rollback acceptance still requires the
  canonical x64 payload or a separately approved promotion transaction.
- ARM64 candidate composition, signing/legal review, and canonical promotion
  remain separate gates and were not attempted.
