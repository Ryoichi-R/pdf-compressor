# PDF Compressor

## 概要

PDF Compressorは、PDFを利用者のPC内で圧縮するWindows向けデスクトップツールです。
PDF本文、診断情報、利用状況を外部サービスへ送信しません。

## 動作要件

- Windows 10またはWindows 11
- x64 CPU、またはWindowsのx64エミュレーションを利用できるARM64 CPU
- 導入先と処理対象PDFを保存できるローカルディスク空き容量

配布payloadに必要な実行環境を同梱するため、利用者によるSDK、compiler、wingetの導入や
管理者権限は不要です。

## インストール

Release assetが掲載されていない時点では、利用者向け配布ZIPは未公開です。GitHubのsource ZIPまたはcloneには、実行に必要なbundled payloadは含まれません。

GitHub Releaseから`pdf-compressor-win-x64.zip`をダウンロードし、任意のローカルフォルダーへ
すべて展開してから`PdfCompressor.App.exe`をダブルクリックしてください。

- ZIP内のフォルダー構成を保ったまま展開してください。
- 旧版から更新する場合は、新しいZIPを別フォルダーへ展開して動作確認してから切り替えてください。
- 出力PDFは必要に応じて旧フォルダーから新しいフォルダーへ移してください。
- GUI設定は`%APPDATA%\pdf-compressor\settings.json`に保存されるため、展開先を変えても保持されます。
- repository直下の導入・更新BATは、検証済みpayloadを`project\installer\payload`へ配置した
  保守・canonical package作成用です。GitHubのsource ZIPまたはclone単体では実行できません。
- 配布payloadはWindows x64のみです。ARM64（Snapdragon等）のPCでは、同じx64 payloadをWindows標準のx64エミュレーションで導入・実行します。native ARM64 payloadは提供していません。
- 本ツールの実行ファイルとscriptは**コード署名されていません（NotSigned）**。初回起動時にWindows SmartScreenの警告が表示される場合があります。同一性の確認は、配布物に併記されたSHA-256と照合してください。

詳細、ライセンス、開発者向け手順は`project\README.md`を参照してください。

## 使用方法

導入先の`PdfCompressor.App.exe`を起動し、PDFまたはPDFを含むフォルダーを追加して
圧縮を実行します。CLIを使用する場合は導入先の`compress.bat`を実行してください。
既定のSafeモードは、暗号化・電子署名・保持できない機能を検出したPDFを安全側に
停止またはスキップします。

## 設定

GUIの出力先、戦略、モード、安全設定、目標bytes、上書き、ウィンドウ位置は
`%APPDATA%\pdf-compressor\settings.json`へ保存されます。署名許可、ページ全体ラスタ許可、
実行ごとの同意情報は保存されません。

## アンインストール

必要な出力PDFを退避してから、ZIPを展開したフォルダーを削除してください。
設定と更新stateも完全に削除する場合は、`%APPDATA%\pdf-compressor`と
`%LOCALAPPDATA%\pdf-compressor`を手動で削除します。

## 既知の制限

- 配布はWindows x64向けのみで、native ARM64、macOS、Linuxには対応しません。
- 実行ファイルとscriptはコード署名されていません。
- OCRはproviderを同梱しない任意機能です。
- 目標bytesは保証値ではなく、PDFの内容によって到達できない場合があります。

## ライセンス

Copyright (c) 2026 Ryoichi-R

PDF Compressor の第一者コードは [MIT License](LICENSE) の条件で提供します。
同梱する第三者コンポーネントには、それぞれのライセンスが適用されます。

第三者のライセンス、通知、対応ソースの取得方法は
`project\THIRD-PARTY-NOTICES.md`、`project\licenses\`、
`project\third-party-source\README.md`を参照してください。上流アーカイブはGit履歴に含めません。
バイナリ配布時は、GhostscriptおよびPopplerの条件を満たすため、同じバージョンの
`pdf-compressor-corresponding-source-win-x64.zip`をGitHub Release assetとして併載します。

## 脆弱性の報告

公開Issueではなく、GitHubのSecurity Advisories（private vulnerability reporting）から
報告してください。詳細は`.github\SECURITY.md`にあります。
