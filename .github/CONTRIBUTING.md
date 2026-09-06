# コントリビューションガイド

## ライセンス

このプロジェクトは GNU Affero General Public License version 3（AGPL-3.0）で提供して
います。プルリクエストを送った時点で、その変更を同じライセンスで提供することに同意
したものとみなします。

## 必要な環境

| 項目       | 要件                                                                         |
| ---------- | ---------------------------------------------------------------------------- |
| OS         | Windows 10 / 11（WinForms GUI と Windows ネイティブ依存のため Windows 専用） |
| PowerShell | **7 以上（`pwsh`）必須**。Windows PowerShell 5.1 は非対応                    |
| .NET SDK   | [`project/global.json`](../project/global.json) が固定するバージョン         |
| Pester     | 5.5 以上                                                                     |

```powershell
winget install --id Microsoft.PowerShell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0
```

外部ツール（Ghostscript / qpdf / Poppler）は開発時のみ必要です。導入は
`project\scripts\setup\install-dependencies.bat` を使います。配布 payload にはこれらを
同梱するため、利用者側の導入は不要です。

## テスト

```powershell
cd project
pwsh -NoProfile -File _internal/run-tests.ps1 -Suite Unit
pwsh -NoProfile -File _internal/run-tests.ps1 -Suite Unit -CodeCoverage
```

- **Unit** — 外部ツール不要。プルリクエストで必ず通してください。
- **Integration** — `installer/payload/` が必要です。payload は 233 MB のビルド成果物で
  リポジトリに含まれないため、payload を持たない環境では失敗します。
- **E2E** — qpdf / Ghostscript / Poppler の実バイナリと fixture provenance が必要です。
  `-AllowMissingExternalTools` はローカル開発時のみ使用してください。

### カバレッジ

[`project/_internal/data/coverage-targets.json`](../project/_internal/data/coverage-targets.json)
が指定する Tier C0 のファイル群に対し、**90% を fail-closed の gate** としています。
この閾値を下げる変更は受け付けません。

### CI が検証しない範囲

CI（[`pdf-compressor-ci.yml`](workflows/pdf-compressor-ci.yml)）は Unit suite、カバレッジ
gate、launcher ビルドのみを実行します。Integration・E2E・payload 契約は 233 MB の追跡外
成果物を要求するため、GitHub 上では再現できません。これらはリリース時にローカルで
`PDF_COMPRESSOR_REQUIRE_PAYLOAD=1` を設定し、fail-closed で実行します。

## コーディング規約

[`project/.editorconfig`](../project/.editorconfig) が正本です。

- 改行コード: 既定は **CRLF**。Markdown のみ **LF**。
- 文字コード: UTF-8（BOM なし）。**例外**: `project/_internal/gui.ps1` は
  **UTF-8 BOM 付き必須**。PowerShell 5.1 が日本語リテラルを文字化けさせるためで、
  `tests/unit/gui_encoding.Tests.ps1` が強制しています。
- インデント: 4 スペース（Markdown は 2）。
- `.bat` に日本語を書かないでください（cmd.exe の UTF-8 の問題）。ファイル名の日本語は
  例外として許容しています。

### 外部プロセス呼び出し

外部ツールへの引数は **必ず配列**（`ProcessStartInfo.ArgumentList` または PowerShell の
配列）で渡してください。文字列補間でコマンドラインを組み立てないでください。
`tests/unit/invoke_args.Tests.ps1` が検証しています。

### パス境界

書き込みは `_internal/path-guard.ps1` の `Assert-WritePathInsideTool` を通してください。
UNC、`\\?\` / `\\.\` 長パス、相対パス、reparse point 配下はいずれも拒否します。
この境界を迂回する経路を追加しないでください。

## プルリクエストの前に

1. `pwsh -NoProfile -File _internal/run-tests.ps1 -Suite Unit` が通ること
2. `pwsh -NoProfile -File _internal/run-tests.ps1 -Suite Unit -CodeCoverage` が 90% を維持すること
3. `dotnet build PdfCompressor.slnx -c Release` が警告ゼロで通ること
   （`TreatWarningsAsErrors` が有効です）
4. 新機能には unit テストを追加すること
5. 設計に関わる変更は [`project/_internal/ARCHITECTURE.md`](../project/_internal/ARCHITECTURE.md) を更新すること

## 変更を避けてほしい箇所

- **安全既定値**: Safe モードでの暗号化・電子署名付き PDF の SKIP、ページ全体ラスタ戦略の
  明示同意要求。緩和する変更は、理由と代替の安全策を添えてください。
- **payload マニフェストのスキーマと検証**: 配布物の完全性 gate に直結します。
- **終了コード契約**: CLI 互換性を壊します。
