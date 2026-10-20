# Third-party archives

This directory is a local cache for upstream runtime and corresponding-source
archives. Downloaded archives are intentionally excluded from Git history.

From the `project` directory, obtain the pinned Windows x64 dependencies and
their common corresponding sources with:

```powershell
pwsh -NoProfile -File installer/dependencies/Get-PortableDependencies.ps1 `
  -Runtime win-x64 `
  -DestinationRoot third-party-source `
  -IncludeCommonSources
```

The downloader uses the official URLs in
`installer/dependencies/download-sources.json` and verifies every file against
the SHA-256 values in `installer/portable-dependencies.json`.

Binary releases must publish the matching
`pdf-compressor-corresponding-source-win-x64.zip` as a GitHub Release asset.
That generated bundle is not committed to this source repository.
