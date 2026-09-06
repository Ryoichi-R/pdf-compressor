# セキュリティポリシー

## 脆弱性の報告

**GitHub の Security Advisories（private vulnerability reporting）から報告してください。**
このリポジトリの `Security` タブ → `Report a vulnerability` から非公開で送信できます。

公開 Issue には書かないでください。修正版を出すまで詳細が公開されると、利用者が危険に
さらされます。

個人で開発・保守しているため、応答は速報性を保証できません。目安として初回応答まで
7 日程度を見込んでください。

## 対象範囲

### 対象に含まれるもの

- PDF Compressor 自身のコード（`project/_internal/`、`project/src/`、`project/installer/`）
- インストーラーの権限昇格、任意ファイル書き込み、パス境界の回避
- 同梱ツールへ渡す引数の組み立て（コマンドインジェクション）
- payload 検証（SHA-256、マニフェスト）の回避
- 悪意ある PDF による、PDF Compressor 側の想定外挙動

### 対象に含まれないもの

- **同梱している第三者ツール自体の脆弱性**（Ghostscript、Poppler、qpdf、PowerShell、.NET）。
  それぞれの upstream へ報告してください。ただし、報告いただければ同梱バージョンの
  更新判断に反映します。
- コード署名がないこと。既知かつ意図的な状態です（下記）。
- 利用者が自ら書き換えたインストール先での動作。

## 同梱依存の更新方針

Ghostscript は PDF 解釈の性質上、脆弱性が継続的に報告される依存です。同梱バージョンと
その SHA-256 は [`project/installer/portable-dependencies.json`](../project/installer/portable-dependencies.json)
と [`project/installer/DEPENDENCY-AUDIT.md`](../project/installer/DEPENDENCY-AUDIT.md)
に固定・記録しています。

- 同梱依存に、この製品の利用経路から到達可能な脆弱性が公表された場合、依存を更新した
  payload を再ビルドして配布します。
- 依存の更新は payload の再ビルドと再検証を伴うため、リリースは即時ではありません。
- 到達可能性が無いと判断した場合は、その判断根拠を `DEPENDENCY-AUDIT.md` に記録します。

## 完全性の検証（重要）

**このソフトウェアの実行ファイルとスクリプトはコード署名されていません（NotSigned）。**
署名鍵の調達・保管・更新責任が成立していないため、意図的に未署名としています。

したがって、入手した配布物が正規のものであることは **SHA-256 の照合でのみ確認できます**。

```powershell
Get-FileHash -Algorithm SHA256 .\pdf-compressor-win-x64.zip
```

得られた値を、Release ページに併記された値と照合してください。一致しない配布物は
使用しないでください。初回起動時に Windows SmartScreen の警告が出ますが、これは未署名
であることによるもので、照合が一致していれば想定内の挙動です。

## データの取り扱い

PDF Compressor はローカル処理専用です。テレメトリー送信、クラウド送信、PDF 本文の外部
送信のいずれも行いません。ネットワーク通信を行うのは、開発者向けの依存導入スクリプト
（`project/scripts/setup/`）だけです。

処理対象 PDF と出力は、インストール先配下および利用者が指定した出力先にのみ書き込まれ
ます（`project/_internal/path-guard.ps1` による境界強制）。設定は
`%APPDATA%\pdf-compressor\`、更新状態は `%LOCALAPPDATA%\pdf-compressor\` に保存されます。
