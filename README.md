# uapp_e2e-kit

Unity製モバイルアプリの **E2Eテスト導入キット**（対応プラットフォーム: **Android / iOS**。
iOS の実行は macOS のみ）。
自作計装 **E2EBridge**（アプリ内TCPサーバー）＋ **Pythonドライバ**（pytest）で、
エミュレーター/実機上のアプリを UI 階層ベースで操作・検証する。
キット本体は **MIT ライセンス**で、**有料ツール・有料ライセンスに依存しない**。
Claude Code 等の AI エージェントによる自律テスト開発を前提に設計している。

## 特徴

- **Windows / macOS 両対応**（v0.1.8）: 同じスクリプトを PowerShell 7 で実行する。
  macOS は Intel / Apple Silicon の実機で検証済み（`SETUP.md` の「macOS で使う場合」参照）
- **iOS 対応**（v0.1.9・macOS のみ）: シミュレータ・実機の両経路を同梱
  （`build-ios.ps1` → `run-ios-e2e.ps1`。シミュレータは署名不要、実機は Apple Development 署名）。
  アプリ外の操作・OS 合成後のスクリーンショット用に **XCUITest ベースの OS レイヤーエージェント**も
  同梱（`-OsAgent`）。iOS だけで使う構成は `install-to-project.ps1 -Mode ios` で導入する。
  **制約が Android と同等ではない**ため、設計前に `SETUP.md` の「iOS で使う場合」を読むこと
- **本番安全**: ランタイム計装は `UAPP_E2E_BRIDGE` スクリプティングdefine のあるビルドにのみ含まれる
  （asmdef defineConstraints。Editor 拡張はエディタ専用アセンブリで、プレイヤービルドには元々入らない）。
  リリースビルドには混入しない
- **UI階層で操作**: 座標ではなく要素名/パスで dump→resolve→tap。遮蔽検知（hittable / blockedBy）付きで
  「タップできないのに成功扱い」を防ぐ。階層が大きいプロジェクトでは **`hittables`**（v0.1.15）で
  いま押せるものだけを取れる（`dump` は画面に出ていない枝まで JSON にするため、実プロジェクトでは
  秒単位になることがある）
- **画面の文字を読む**: **`texts`**（v0.1.16）は見出し・残数表示・セリフのような
  **押せないが読みたいテキスト**を型で絞って取る（`hittables` は押せる要素のテキストしか返さない）。
  **型も範囲も呼ぶ側が決める**ので、TMP・uGUI・NGUI・独自の表示部品のどれでも同じ口で読める
- **uGUI / NGUI 両対応**、Input System・レガシー Input 両対応（`e2e-config.json` の `uiType` で切替）
- **タップ・ドラッグ・ピンチ・複数ポインタの同時操作**（press/release）のジェスチャ注入、
  `wait_until_*` による待機（sleep に頼らない）
- **UI を経由しない入力にも対応**（v0.1.4）: キーボード・マウス・ゲームパッドを直接注入できる。
  「キーが押された」「パッドのボタンが押された」を自前で読んでいるゲームコードも E2E から操作できる。
  注入先は専用の仮想デバイスなので、**PC に接続された実機のパッドと混ざらない**
  （`input_devices` で接続状況を確認できる）
- **エディタ再生に直結する高速ループ**: エディタで Play 中のアプリへ、ビルド・デバイス・adb なしで
  直接接続できる（`BridgeClient()` が `e2e-config.json` の `editorBridgePort` を自動解決。
  `UAPP_E2E_EDITOR=1` で pytest もそのまま実行可能。adb を使うテストは明示エラーになり誤検証しない）
- **人手ゼロのエディタE2E**: [Unity CLI](https://docs.unity.com/en-us/unity-cli) を入れておくと
  `run-e2e.ps1 -Editor` の1コマンドで「エディタ起動 → シーンを開く → Game view 解像度設定 → Play →
  pytest → Play 終了」まで自動実行（コールドスタート約60秒。Unity 6 以降）。
  他タスクが Play 中なら中断し、未保存シーンは保護する。
  **エディタ直結でもスクリーンショットを残す**（ジャーニーの画面画像・失敗時の証跡。v0.1.4）
- **1 つのキットを多数の clone で使い回せる**（v0.1.12）: 同一プロダクトの clone が並ぶ運用向けに、
  **キットは 1 か所（ハブ）へ置き、対象へ一時的に注入して使う**モードを同梱
  （`inject-to-project.ps1` / `-Eject`）。対象へ置くのは計装・define・パッケージ参照・ポート設定だけで、
  **撤去は記録ベース**（入れた物を対象へ記録し、それだけを戻す。記録が無い対象には触らない）。
  ポート台帳が clone ごとに `editorBridgePort` を割り当てるので、**別プロジェクトのエディタへ
  誤接続する事故を防ぐ**。注入→撤去で対象のファイルがバイト一致に戻ることを実測している
- **Android を使わない運用にも対応**（v0.1.4）: `install-to-project.ps1 -Mode editor` で、
  エディタ直結E2Eだけで回す構成として導入できる（`package` / `activity` / AVD を必須扱いにしない。
  `UAPP_E2E_BRIDGE` define の確認も、Build Settings で選んでいるプラットフォームに合わせて判定する）
- **内側ループ（C#テスト）も1コマンド**: `run-unity-tests.ps1` で EditMode/PlayMode テストを実行し、
  失敗したテスト名・メッセージ・該当行を要約表示する（Unity CLI が無ければ Unity 本体の
  batchmode へ自動フォールバック。**CLI 側が不調なときは `-NoUnityCli` で Unity 本体の経路に
  直接入れる**。指定しなくても CLI が 60 秒応答しなければ警告を出して切り替わる。v0.1.5）
- **UI を経由しない入力も注入できる**（v0.1.4）: キーボード・マウス・ゲームパッドを**専用の仮想デバイス**へ
  注入するので、`tap(path)` では動かせない「キーが押された」を直接読むゲームコードを E2E から操作できる
  （PC に刺さっている実機と混ざらない。仮想デバイスは種別ごとに初回注入時に生成され、
  `input_devices()` の `virtualDevices` で生成状況が分かる。v0.1.5）。
  **エディタ再生では Game view のフォーカス状態に左右されない**（v0.1.6）— 既定の Input System 設定では、
  Game view が他のビューにフォーカスを奪われている間は `wasPressedThisFrame` 等のポーリングに
  入力が届かない。注入時だけルーティングを切り替えて回避する（Play 終了時に元へ戻す）
- **ジャーニー記録**: テスト実行から画面遷移マップ＋スクリーンショット＋カバレッジの
  自己完結HTMLレポートを自動生成（[docs/07-viewer.md](docs/07-viewer.md)）
- **AI向けランブック同梱**: [SETUP.md](SETUP.md)（導入手順書）と e2e-setup / e2e-run / e2e-write-test /
  e2e-dump の4スキルで、AI に「セットアップして」と頼むだけで導入できる。スキルは **Claude Code**
  （`.claude/skills/`、`/e2e-run` 等）と **OpenAI Codex CLI v0.94.0+**（`.agents/skills/`、`$e2e-run` 等）の
  両対応（installer の `-Agents claude|codex|both` で選択、既定 both・後から追加可）
- **クリーンに外せる**: 同梱の `uapp_e2e\scripts\uninstall.ps1` でアンインストール
  （既定は設定・自作テストを残して外す＝installer 再実行で復帰。`-Purge` で全削除）

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

- 対象アプリ: Unity製 Android / iOS アプリ（エミュレーター・シミュレータ/実機どちらも可。
  **iOS のビルド・実行は macOS ＋ Xcode ＋ Unity iOS Support モジュールが必要**）
- **Windows または macOS** + PowerShell 7（スクリプト類は同じ `.ps1` を `pwsh` で実行。
  macOS は Intel / Apple Silicon の実機で検証済み。導入手順と既知の差分は同梱 `SETUP.md` の
  「macOS で使う場合」を参照）
- Python 3.10 以降（3.12 で検証。ドライバの依存パッケージは pytest のみ）
- Android SDK Platform-Tools（adb）。エミュレーター利用時は AVD も
  （**エディタ再生への直結だけで使う場合は adb 不要**）
- Unity 2022.3 系〜 Unity 6000 系で検証済み
- AIエージェント（任意・人手運用も可）: Claude Code、または OpenAI Codex CLI v0.94.0 以降
- [Unity CLI](https://docs.unity.com/en-us/unity-cli)（任意）: `run-e2e.ps1 -Editor`（エディタ直結E2Eの
  自動化）に必要。**Unity 6 以降**が対象（`com.unity.pipeline` の要件）。
  `run-unity-tests.ps1` は Unity CLI が無くても動く（batchmode へ自動フォールバック。
  CLI を入れていて不調な場合は `-NoUnityCli`）。CLI は認証セッションが切れると無言で長時間
  応答しなくなるため、応答しないときは `unity doctor` / `unity auth login` を確認する

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
