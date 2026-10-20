# Changelog

このファイルの書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に従い、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

このリポジトリは 2026-09-04 まで changelog を持たなかった。それ以前の詳細な実装経緯は
コミット履歴と `_internal/ARCHITECTURE.md` を参照すること。

## [Unreleased]

### Added

- 第一者コードを MIT License とし、`Copyright (c) 2026 Ryoichi-R` を README、
  `THIRD-PARTY-NOTICES.md`、launcher の assembly metadata（`Product` / `AssemblyTitle` /
  `Company` / `Authors` / `Copyright`）に追加。これまで未署名 exe のファイルプロパティが
  空欄だった。
- 対応ソースアーカイブに **win-x64 の build recipe を同梱**するようにした
  （`Build-Poppler.ps1` / `poppler-vcpkg.json` / `Test-PopplerSourceSignature.ps1`）。
  Ghostscript の AGPL-3.0 と Poppler の GPL-2.0-or-later に従い、対応ソースと再現に必要なビルドレシピを配布物へ結び付ける。従来これらは win-arm64 でしか同梱していなかった。
- パッケージ直下 `README.md` と配布テンプレート `installer/assets/root-README.md` の
  byte 一致を強制する契約テストを追加した。root entry BAT には同種の契約があったが
  README には無く、コード署名の開示文が片方だけに存在する drift を検出できていなかった。
- payload 契約テストに `PDF_COMPRESSOR_REQUIRE_PAYLOAD=1` を追加した。設定時は payload
  不在を Skip ではなく失敗として扱う（リリース検証用の fail-closed スイッチ）。
- GitHub Actions ワークフローを追加した。Unit suite、Tier C0 カバレッジ gate、launcher
  ビルドを windows runner で実行する。

### Changed

- `_internal/ARCHITECTURE.md` の非干渉に関する記述を、特定の兄弟プロジェクト名への依存を
  やめて path-guard 中心に書き換えた。

### Removed

- `tests/unit/non_interference.Tests.ps1` を削除した。同一ワークスペース内の別プロジェクト
  が改変されないことを検証するテストで、単独リポジトリでは検証対象が存在せず常に Skip
  される fail-open な状態だった。境界検証は `tests/unit/path-guard.Tests.ps1` が担う。
- `installer/Build-Payload.ps1` から、`return` 以降で実行されない legacy 実装 82 行を
  削除した（97 行 → 15 行）。存在しないパスを参照しており誤読の原因になっていた。
- 一回限りの内部移行記録 `_migration/` をリポジトリから除いた。

## [1.1.0] — 未リリース

ビルドは存在したが、**一般公開は行われていない**。外部の公開先・Release・artifact は
2026-08-17 の照合で特定できず、`UNVERIFIED_EXTERNAL_TARGET` と判定されている。

主な内容:

- Ghostscript / qpdf / Poppler を PowerShell から駆動する PDF 圧縮ツール。GUI（WinForms）
  と CLI の両方を提供する。
- 8 種類の圧縮戦略と自動判定。目標容量指定は最大 7 候補を試行する。
- Safe / Warn / Off の安全ポリシー。Safe 既定では暗号化・電子署名付き PDF を SKIP する。
  ページ全体をラスタ化する戦略は明示同意を要求する。
- 候補は `_work` 上で qpdf check、ページ数、MediaBox / CropBox、Rotate、安全機能の比較に
  合格したものだけを正式出力する。
- ワンクリック導入・更新インストーラー。PowerShell 7、Ghostscript、qpdf、Poppler を同梱
  するため、利用者側の SDK・コンパイラ・winget・管理者権限は不要。
- 配布は win-x64 のみ。ARM64 ホストでは同じ x64 payload を Windows 標準の x64
  エミュレーションで動作させる。
- ローカル処理専用。テレメトリー、クラウド送信、PDF 本文の外部送信は行わない。
- **コード署名なし（NotSigned）**。完全性の確認は SHA-256 の照合による。

### ARM64 native payload の状況（未配布）

native ARM64 payload は**配布していない**。技術検証としては、2026-09-01 に PowerShell
7.6.3、qpdf 12.3.2、Poppler 26.07.0、Ghostscript 10.07.1、launcher からなる ARM64 native
dependency chain を固定ソースと再現レシピから構築し、2026-09-02 に非 canonical な
`arm64-only` 候補で Unit・strict E2E・Integration・意味比較・性能比較を完了している
（x64 エミュレーション比 54.01% 短縮）。ARM64 実機でのインストーラー受入は 10/10 ケース
通過。

未完了の項目: 手動 GUI 受入、独立した x64 ホストでの回帰、署名と法的最終確認、canonical
への昇格判断。詳細は `installer/DEPENDENCY-AUDIT.md` を参照すること。
