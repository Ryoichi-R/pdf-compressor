# Dependency and redistribution gate (updated 2026-09-02)

> Paths under `result/pdf-compressor/` in this document and in
> `installer/portable-dependencies.json` are **owner-local evidence** produced during
> verification. They are deliberately excluded from the published repository, so a
> public checkout will not contain them. The values that a third party can verify
> independently are the pinned SHA-256 digests, the upstream provenance URLs, and the
> Poppler detached signature, all of which are reproduced below.

Gate result: **GO for the canonical win-x64 payload**. A complete native
win-arm64 candidate has passed technical build and automated validation, but
**canonical promotion and redistribution remain NO-GO** until the owner gates,
manual acceptance, and legal/trust-boundary decisions listed below are complete.

- PowerShell 7.6.3: official portable ZIP; SHA-256 matches
  `07DDB0D00B660459560EF82A9841DA7705B27CD5DCCA5A0D7B025A98ECA29ECA`;
  MIT license and notices included.
- qpdf 12.3.2: official MSVC64 ZIP; SHA-256 matches
  `8941870A604E7C87ED24566B038D46C24CE76616254D2383C578F60C0677F202`;
  Apache-2.0 license.
- Poppler 26.07.0: official source archive; SHA-256
  `304832F48F8A47FDCA90C6B6D1F684E68F37C10C9A0726F345F4CA9DF4CA01E2`;
  locally built with MSVC and pinned vcpkg baseline. `pdfinfo`, `pdfimages`,
  and `pdftoppm` report version 26.07.0. GPL-2.0-or-later texts and source
  archive included. The official detached signature was verified with
  GnuPG `gpgv` 2.4.8. `VALIDSIG` bound the archive to Poppler release signer
  Albert Astals Cid's official fingerprint
  `CA262C6C83DE4D2FB28A332A3A6A4DB839EAA6D7`. Archive, signature, public-key,
  and keyring SHA-256 values are pinned and rechecked by
  `installer/dependencies/Test-PopplerSourceSignature.ps1`. Evidence and
  limitations are recorded in
  `result/pdf-compressor/poppler-signature-verification-20260813.json`.
- Ghostscript 10.07.1: official Windows installer SHA-256
  `3A4C28D0AAC47AA7CCCD35A5932C55110376E9DBD966898DDE388B7FABA444A4`;
  official source SHA-256
  `1CDB766DE8DB8F1E589C817F09C5855EA5F65DFC8540E465A69AC14C18416025`.
  Runtime reports 10.07.1. AGPL-3.0 text and corresponding source archive
  included.

The first-party application code is licensed under MIT. Bundled third-party components retain their own licenses. No OCR provider is
bundled. The canonical package remains x64-only: a native ARM64 candidate has
been built, but it has not been promoted or shipped. ARM64 hosts therefore install the same
verified win-x64 payload and run it under Windows built-in x64 emulation.
The installer now accepts `win-arm64` only when that runtime is present in the
manifest and passes the runtime-specific validator; the canonical manifest
does not advertise it, so the current package remains fail-closed.

## ARM64 candidate provenance

The dependency ledger records ARM64 as a separate runtime projection. The
PowerShell 7.6.3 win-arm64 ZIP has the official SHA-256
`2ECE90557C370BB5EE03275EF41F2A49E26EA85DEFCF2052ACA32C20DADB62C2`.
qpdf 12.3.2, Poppler 26.07.0, and Ghostscript 10.07.1 have no adopted
official Windows ARM64 runtime artifact in the current ledger. All three were
therefore built from pinned official source on the ARM64 host with native MSVC,
fixed recipes, and no source patches; no third-party prebuilt binary was used.

- qpdf: source SHA-256 `6CBA2F9F2CD887D905FAEB99E0E51A307B217920D1BBF3E9CFBB2E8178A2DEDA`,
  runtime ZIP SHA-256 `8CE7BCCBB134FFAC0305BBC987C4F706A8EB727804DCA45CD04612101EF10AC1`.
  The six-file closure is ARM64 and version/basic-operation checks passed.
- Poppler: the signature-verified source listed above, fixed vcpkg baseline
  `c1d80d9cb071c3f4a98c67c1196b137cc5b72918`, triplet `arm64-windows`,
  runtime ZIP SHA-256 `073986160BCD0886891EAFF40020DBE8E56B2F3886CC719F559211B3A66958F6`.
  The 20-file closure is ARM64 and the four required utilities passed.
- Ghostscript: source SHA-256 listed above, runtime ZIP SHA-256
  `68014ED6514AA9DDA2F563B90FBED63BD77E563ECC351B40292A0F651FA459AD`.
  `pdfwrite` and `pdfimage24` passed the product fixture, with SSE2 and unused
  OCR excluded.

The current non-canonical candidate is
`installer/candidates/20260902-arm64-owner-approved-3`, schema v3 release ID
`pdfc-release-4cbe1abbdd0493ea`, build ID
`pdfc-1.1.0-win-arm64-1d9cd9df20567bd5`. Its payload SHA-256 is
`CD41F109D9DD53AB3865DB597CF9A63974ACC0E5F6A640BBE4F56C9A13A747A8`;
all required native EXE/DLL files are ARM64, full extraction and diagnostics
passed. Its `arm64-only` entry BAT SHA-256 is
`34107504DF6009AE9B6DAC7D80C39838617BAD83E6821B51250CD3622284984E`.
The corresponding-source SHA-256 is
`2E64248502535F9692D3FCBB8118751BB012CD731D432CDA28713B08F3B10E2D`
and binds product/installer source, dependency source archives, and build recipes.
Unit (405 passed, 2 skipped), strict E2E (18/18), and Integration (4/4) passed
on the ARM64 host. Evidence is summarized in
`result/pdf-compressor/arm64-owner-approved-candidate-20260902.md`.

Source-built payload provenance is a fixed source archive hash plus the build
recipe/dependency digest. This is materially different from the official-binary
SHA-256 provenance used by the x64 payload. On 2026-09-02 the owner accepted this
model subject to pinned official sources, fixed recipes and dependency baselines,
no unrecorded patches, and architecture/fixture tests. The owner also accepted a
30% performance threshold (observed 54.01%), architecture-specific packages, and
unsigned candidates only for owner-controlled local testing. Manual GUI acceptance,
independent x64-host regression, signing/legal review, and an explicit canonical
promotion decision remain required before redistribution.

Verified on an ARM64 host (Snapdragon X Plus / Windows 11 26200, 2026-08-14):
payload verification, install, GUI launch, and a CLI compression run all
succeeded under x64 emulation, with `pwsh` 7.6.3, `qpdf` 12.3.2,
`pdfinfo` 26.07.0, and `gswin64c` 10.07.1 all reporting their bundled versions.
