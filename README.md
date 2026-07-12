# uapp_e2e-kit

Unity製モバイルアプリの **E2Eテスト導入キット**（対応プラットフォーム: **Android**）。
自作計装 **E2EBridge**（アプリ内TCPサーバー）＋ **Pythonドライバ**（pytest）で、
エミュレーター/実機上のアプリを UI 階層ベースで操作・検証する。
キット本体は **MIT ライセンス**で、**有料ツール・有料ライセンスに依存しない**。
Claude Code 等の AI エージェントによる自律テスト開発を前提に設計している。

## 特徴

- **本番安全**: ランタイム計装は `UAPP_E2E_BRIDGE` スクリプティングdefine のあるビルドにのみ含まれる
  （asmdef defineConstraints。Editor 拡張はエディタ専用アセンブリで、プレイヤービルドには元々入らない）。
  リリースビルドには混入しない
- **UI階層で操作**: 座標ではなく要素名/パスで dump→resolve→tap。遮蔽検知（hittable / blockedBy）付きで
  「タップできないのに成功扱い」を防ぐ
- **uGUI / NGUI 両対応**、Input System・レガシー Input 両対応（`e2e-config.json` の `uiType` で切替）
- **タップ・ドラッグ・ピンチ・複数ポインタの同時操作**（press/release）のジェスチャ注入、
  `wait_until_*` による待機（sleep に頼らない）
- **ジャーニー記録**: テスト実行から画面遷移マップ＋スクリーンショット＋カバレッジの
  自己完結HTMLレポートを自動生成（[docs/07-viewer.md](docs/07-viewer.md)）
- **AI向けランブック同梱**: [SETUP.md](SETUP.md)（導入手順書）と Claude Code スキル（/e2e-setup /e2e-run
  /e2e-write-test /e2e-dump）で、AI に「セットアップして」と頼むだけで導入できる

## 導入方法（2経路）

**A. Releases の zip から（推奨）**

1. [Releases](https://github.com/Taichis-K/uapp_e2e-kit/releases) から `uapp_e2e-kit-v<version>.zip` を取得して展開
2. `.\install-to-project.ps1 -ProjectPath <Unityプロジェクト>`
3. 以降は [SETUP.md](SETUP.md) に従う（AI エージェントに任せる場合は「SETUP.md に従ってセットアップして」と依頼）

**B. このリポジトリを clone して**

```powershell
git clone https://github.com/Taichis-K/uapp_e2e-kit.git
cd uapp_e2e-kit
.\install-to-project.ps1 -ProjectPath <Unityプロジェクト>
```

## 動作要件

- 対象アプリ: Unity製 Android アプリ（エミュレーター/実機どちらも可）
- Windows + PowerShell 7（スクリプト類）
- Python 3.10 以降（3.12 で検証。ドライバの依存パッケージは pytest のみ）
- Android SDK Platform-Tools（adb。エミュレーター利用時は AVD）
- Unity 2022.3 系〜 Unity 6000 系で検証済み

Unity・Android SDK・Python 等は別途用意し、それぞれのライセンス・利用規約に従うこと。

## ドキュメント

| ファイル | 内容 |
|---|---|
| [SETUP.md](SETUP.md) | AI向けセットアップランブック（導入の正）|
| [docs/05-install-to-project.md](docs/05-install-to-project.md) | 人間向け導入マニュアル・構成判定・アンインストール |
| [docs/02-protocol.md](docs/02-protocol.md) | E2EBridge JSONプロトコル仕様 |
| [docs/ai-loop.md](docs/ai-loop.md) | AI自律開発ループ・テスト規約・失敗解析 |
| [docs/07-viewer.md](docs/07-viewer.md) | ジャーニー記録とHTMLレポート |

## ライセンス

[MIT](LICENSE)
