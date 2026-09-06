# Third-party notices

PDF Compressor の第一者コードは Copyright (c) 2026 Ryoichi-R であり、MIT License（`LICENSE`）の条件で提供します。第三者コンポーネントには、以下の各ライセンスが適用されます。
次の未改変コンポーネントを同梱します。

| Component | Version | Source / artifact | License |
|---|---:|---|---|
| PowerShell | 7.6.3 | Microsoft official `PowerShell-7.6.3-win-x64.zip` | MIT; bundled notices included |
| qpdf | 12.3.2 | qpdf official `qpdf-12.3.2-msvc64.zip` | Apache-2.0 |
| Poppler | 26.07.0 | freedesktop.org official source tarball; locally built with MSVC/vcpkg | GPL-2.0-or-later |
| Ghostscript | 10.07.1 | Artifex official source and Windows distribution | AGPL-3.0 |
| .NET runtime | 10.0 | Microsoft SDK self-contained publish output | MIT and bundled third-party notices |

ライセンス原文と付随通知は `licenses\` にあります。Poppler と
Ghostscript の対応ソースアーカイブ、ビルド定義、固定ハッシュは
開発用 `installer\portable-dependencies.json` に記録しています。

ARM64 native candidateについては、PowerShell 7.6.3の公式
`PowerShell-7.6.3-win-arm64.zip`のSHA-256を台帳に登録しています。
qpdf、Poppler、GhostscriptのWindows ARM64 binaryは未採用であり、
source-build spike完了前のprebuilt binaryやARM64配布物はこのnoticeの
同梱対象ではありません。ARM64 native candidateを成立させる場合は、
適用patch・build recipe・対応ソースをruntime別に追加します。

Poppler のビルドでは GUI wrapper、C++ wrapper、NSS/GPG/Curl を無効化し、
PDF Compressor が使用する command-line utilities を生成しています。
Ghostscript を含む本配布物を第三者へ提供する場合は、AGPL の
Corresponding Source 提供義務を含む各ライセンス条件を遵守してください。
