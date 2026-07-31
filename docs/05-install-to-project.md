# 実プロジェクトへの導入マニュアル

既存の Unity 製 Android アプリへ E2E 基盤を導入する手順。
**対象プロジェクトへの変更はすべてファイル追加＋設定追記のみ**で、フォルダ削除と define 除去で完全に元へ戻せる。

## 配布モデル

導入に使うのは**自己完結の配布キット `uapp_e2e-kit-v<version>.zip`**（公開リポジトリの Releases で配布。
生成方法・リリース手順は開発側ドキュメント参照）。開発リポジトリを導入先に丸ごと持っていくことはしない。

### リリース手順（開発側）

リリース（公開リポジトリへの同期と Release 作成）は 開発リポジトリの docs/06-release.md を参照
（リリース前チェックリスト → `publish-kit.ps1` で同期・機密語スキャン → 人が確認して push / Release 作成）。

## 対応環境

| 項目 | 要件 |
|---|---|
| Unity | 2022.3 以降を想定（コンパイル検証済み: 2022.3 / 6000.0.58f2 / 6000.2 / 6000.3） |
| UIフレームワーク | uGUI / NGUI（自動検出・リフレクション対応。混在可） |
| 入力 | New Input System または Both（レガシーInputのみのアプリは Both へ変更が必要。既存挙動は変わらない） |
| 追加パッケージ | `com.unity.inputsystem`、`com.unity.nuget.newtonsoft-json`（ともに無料の公式パッケージ） |
| PowerShell | **PowerShell 7（pwsh）以降**。Windows 標準の Windows PowerShell 5.1 は非対応（キットのスクリプトは BOM なし UTF-8 のため 5.1 では日本語が誤解釈され動作しない） |
| AIエージェント | Claude Code、または OpenAI Codex CLI v0.94.0 以降（任意。人手運用も可） |

## 導入後の配置（標準レイアウト）

プロジェクト本体のコードに混ざるのは `Assets/uapp_e2e/` と `uapp_e2e/` の2箇所のみ（名前空間で完結）。
ほかに AI エージェント導線として `.claude/`・`.agents/`（`-Agents` で選択、既定 both）と、
オプトインの ルート `AGENTS.md`（`-RootAgentsMd` 指定時のみ）が増える。

```
<Unityプロジェクト>/
├── Assets/uapp_e2e/E2EBridge/   計装SDK（UAPP_E2E_BRIDGE define時のみコンパイル）
├── .claude/skills/              Claude Code用スキル（/e2e-setup /e2e-run /e2e-write-test /e2e-dump）※-Agents claude/both
├── .agents/skills/              Codex用スキル（同一内容。$e2e-setup 等で呼び出し。Codex CLI v0.94.0以降）※-Agents codex/both
├── .claude/rules/uapp-e2e.md    軽量ルール（uapp_e2e/CLAUDE.md への参照。本体CLAUDE.mdの書き換え不要）※-Agents claude/both
├── AGENTS.md                    （任意・-RootAgentsMd 指定時のみ新規作成。既存があれば一切変更しない）
└── uapp_e2e/                    E2Eキット（git管理。ただし下記gitignore対象を除く）
    ├── CLAUDE.md                AI向け運用ガイド（エージェント共通。プロジェクトのCLAUDE.mdから @uapp_e2e/CLAUDE.md で参照）
    ├── AGENTS.md                Codex等向けポインタ（uapp_e2e/ をCWDに起動した場合に読まれる）※-Agents codex/both
    ├── e2e-config.json          プロジェクト仕様（git管理）
    ├── docs/                    プロトコル仕様・AI運用・導入マニュアル
    ├── scripts/                 build-android / run-e2e / start-emulator
    ├── driver/                  Pythonドライバ + tests/（自アプリのテストをここに書く）
    ├── config/local.sample.json 実行環境設定テンプレ
    ├── config/local.json        ← 各自コピーして作成（gitignore）
    └── Builds/                  ← ビルド成果物（gitignore）
```

## 一番簡単な導入方法（AIに任せる）

Claude Code に次のように依頼するだけでよい（キットの取得から検証まで自律実行される）:

> このE2Eキット（<uapp_e2e-kit-v*.zip の場所 または 展開先>）をこのUnityプロジェクトに
> セットアップして。手順はキット同梱の `SETUP.md` に従って。

**AI向けの入口ファイルは `uapp_e2e/SETUP.md`**（環境自動検出→設定生成→検証までのランブック）。
セットアップ後は `/e2e-setup` スキルとして再実行・修復も可能。
以下は同じ内容を人間が手動で行う場合の手順。

### Codex（OpenAI Codex CLI）で使う場合

- 対応バージョン: **Codex CLI v0.94.0 以降**（プロジェクト同梱スキル `.agents/skills` の探索に対応した版）
- スキルは導入時に `.agents/skills/` へ配置済み（`-Agents claude` で導入済みの環境は
  `-Agents codex` で installer を再実行すると追加される）。`$e2e-setup` のような `$` 言及、
  または `/skills` からの選択で呼び出す（SKILL.md の形式は Claude Code と共通のため、内容は `.claude/skills/` と同一）
- Codex はルート起動時に `uapp_e2e/AGENTS.md` を自動では読まない（サブディレクトリの AGENTS.md は
  そこを CWD にした場合のみ読込）。ルートに `AGENTS.md` が無いプロジェクトは installer の
  `-RootAgentsMd` でポインタを新規作成すると、規約・失敗解析手順への導線がルート起動でも効く。
  既存の `AGENTS.md` があるプロジェクトでは installer が統合用スニペットを表示するので手動で統合する

## 手順（手動）

### 1. キットのコピー（自動）

配布キット zip を展開し、その直下で：

```powershell
.\install-to-project.ps1 -ProjectPath D:\path\to\YourUnityProject
```

（installer はキット展開先・開発リポジトリのどちらのレイアウトからでも実行でき、同じ結果になる）

`Assets\uapp_e2e\E2EBridge`・`uapp_e2e\`一式（scripts / driver / docs / CLAUDE.md / e2e-config.json テンプレ）と
AIエージェント導線が配置される。サンプルテストも参考に欲しい場合は `-IncludeSampleTests` を付ける。

**AIエージェント導線は `-Agents` で選択できる**（既定 `both`。E2EBridge・driver・docs 等の共通部は選択に関係なく常に配置）:

| 指定 | 配置されるもの |
|---|---|
| `-Agents claude` | `.claude/skills/` + `.claude/rules/uapp-e2e.md` |
| `-Agents codex` | `.agents/skills/` + `uapp_e2e/AGENTS.md` + ルート `AGENTS.md` の案内/`-RootAgentsMd` |
| `-Agents both`（既定） | 上記すべて |

- **後から追加できる**: installer は再実行安全なので、`claude` で導入済みの環境に `-Agents codex` で
  再実行すれば codex 分だけ追加される（逆も同様）
- **自動削除はしない**: `both` で入れた後に `-Agents claude` で再実行しても `.agents/` は消えない。
  外し方は本書のアンインストール手順を参照

Codex ユーザーでルートに `AGENTS.md` が無い場合は `-RootAgentsMd` を付けると発見用ポインタを新規作成する
（既存の `AGENTS.md` は上書き・追記とも行わない。統合スニペットは installer が末尾に表示する。
`-Agents claude` 指定時は無効）。

### 2. パッケージ追加

`Packages/manifest.json` に追記（バージョンは Unity に合わせる）：

```json
"com.unity.inputsystem": "1.7.0",            // 2022.3系。Unity 6系は "1.14.0" 以降
"com.unity.nuget.newtonsoft-json": "3.2.1"
```

- 初回オープン時に「新しい入力バックエンドを有効化しますか？」→ **Yes**
  （聞かれない場合は Player Settings > Active Input Handling を **Both** に。レガシー入力の挙動は変わらない）
- 既に Newtonsoft の DLL を Plugins に持つプロジェクトはパッケージ追加せず、それを使う
  （重複するとコンパイルエラーになるため要確認）

### 3. e2e-config.json の編集

```json
{
  "package": "com.yourcompany.yourapp",      // 実アプリのapplicationId
  "activity": "com.unity3d.player.UnityPlayerActivity",  // カスタムActivityならそれ
  "tests": "tests",                          // テストのパス（uapp_e2e/driver/からの相対。既定はディレクトリごと＝同梱の単体テスト＋疎通スモーク＋自作テスト）
  "orientation": "landscape",                // portrait | landscape | auto（横画面アプリはlandscape）
  "deviceRotation": null,                    // 縦横両対応で起動向きを固定したい場合 0-3
  "devicePort": 13333,                       // デバイス内でブリッジが待ち受けるポート（計装アプリを複数入れる場合はアプリごとに分ける）
  "editorBridgePort": 13333,                 // エディタ再生時の待ち受けポート（複数プロジェクト並行開発時は重複させない）
  "uiType": "ugui-nis"                       // ugui-nis | ugui-legacy | ngui-nis | ngui-legacy（操作APIの選択に使う）
}
```

### 4. UAPP_E2E_BRIDGE define の付与

テスト用ビルドにのみ `UAPP_E2E_BRIDGE` を付与する（**本番ビルドには付けない**。define が無ければ
計装はアセンブリごと除外される）。自前ビルドスクリプトへの組込み例：

```csharp
var defines = PlayerSettings.GetScriptingDefineSymbols(NamedBuildTarget.Android)
    .Split(';', StringSplitOptions.RemoveEmptyEntries).ToList();
if (!defines.Contains("UAPP_E2E_BRIDGE")) defines.Add("UAPP_E2E_BRIDGE");
PlayerSettings.SetScriptingDefineSymbols(NamedBuildTarget.Android, string.Join(";", defines));
```

エディタ再生で使う場合は Player Settings の Scripting Define Symbols に追加する。
**追加先は Build Settings で選んでいるプラットフォーム**（エディタはアクティブなビルドターゲットの
define でコンパイルする）。Android のままエディタ再生する構成でも、Standalone に切り替えた構成でも、
その選んでいるターゲットに付いていればよい。

installer の残手順は **`UAPP_E2E_BRIDGE` が付いているターゲット名を列挙する**ので、
Build Settings の Platform と突き合わせて判断する。判定は運用モードで変わる:

| `-Mode` | 判定 |
|---|---|
| `both`（既定）/ `device` | **Android に付いていること**（APK に計装を入れるため） |
| `editor` | **どれか 1 つのターゲットに付いていること**（プラットフォームは問わない） |

### 4.1 エディタ専用運用（Android を使わない）

デスクトップ向けや「まずエディタ直結E2Eだけで回す」立ち上げ期は `-Mode editor` で導入する。

```powershell
.\install-to-project.ps1 -ProjectPath <対象> -Mode editor
```

- define の判定が上記のとおりプラットフォーム非依存になる
- `e2e-config.json` の `package` / `activity` は**使わないので空でよい**（判定対象から外れる）
- `config\local.json` の `avd` は不要
- 実行は `run-e2e.ps1 -Editor` と `run-unity-tests.ps1 -Mode EditMode -Editor`

### 5. 実行環境設定（各自）

```powershell
cd <プロジェクト>\uapp_e2e
copy config\local.sample.json config\local.json   # 各自の環境に合わせて編集
```

| キー | 内容 |
|---|---|
| `avd` | 使用する AVD 名 |
| `bridgePort` | adb forward のホスト側ポート（エディタと併用するなら 13334 等に） |
| `editorRoots` | Unity のインストール先ルート（C/D混在可、配列で列挙） |
| `editorOverrides` | プロジェクト別のエディタパス個別指定（Hub管理外の配置向け） |

`.gitignore` に `uapp_e2e/config/local.json` と `uapp_e2e/Builds/` を追加すること。

### 6. 疎通確認

```powershell
cd <プロジェクト>\uapp_e2e
pip install -r driver\requirements.txt
.\scripts\start-emulator.ps1
.\scripts\build-android.ps1        # キットがプロジェクト内にある場合は -ProjectPath 不要（自動検出）
.\scripts\run-e2e.ps1              # まだテストが無ければ次の1行で疎通だけ確認：
cd driver
python -c "from e2e_driver import BridgeClient; print(BridgeClient(port=<ホスト側ポート>).connect().ping())"
```

デバイス疎通ではホスト側ポート（`config\local.json` の `bridgePort`）を明示する。
無引数の `BridgeClient()` はエディタ向けに `e2e-config.json` の `editorBridgePort` を解決するため、
デバイスの forward 先と一致するとは限らない。

`ping` の応答に `'ngui': True/False` が含まれ、NGUI検出が確認できる。
以降のテストの書き方は [docs/ai-loop.md](ai-loop.md) の規約に従う（まず dump を見る）。

## UIフレームワーク別の注意

| 構成 | タップ/マルチタッチ | 補足 |
|---|---|---|
| uGUI + New Input System | `Gestures.tap / press / pinch` | EventSystem は `InputSystemUIInputModule` であること |
| NGUI + New Input System | 同上（Touchscreen注入が届く） | 入力ラッパーのNIS読み配線が前提 |
| NGUI + レガシーInput | `ngui_tap / ngui_press / ngui_release`（＋実入力検証は adb タップ） | `pointer_*` は届かない |

見分け方: NGUI の `UICamera.cs`（または入力ラッパー）が `Input.touchCount` を直読みしていればレガシー構成。

## エディタ再生での利用

1. Scripting Define Symbols に `UAPP_E2E_BRIDGE` を追加してプレイ開始
2. ブリッジが `e2e-config.json` の `editorBridgePort` で待ち受ける（adb不要）
3. `BridgeClient()` で直接接続（`e2e-config.json` の `editorBridgePort` を自動解決。明示指定も可）
4. pytest を流す場合はエディタ直結モードで（デバイス/AVD/adb 不要）:
   ```powershell
   cd uapp_e2e\driver
   $env:UAPP_E2E_EDITOR = "1"; pytest tests; Remove-Item Env:\UAPP_E2E_EDITOR
   ```
   対象は adb を直接使わないテストのみ。logcat アサートや adb タップを含むテストは
   エディタ直結モードでは明示エラーになる（端末側を誤検証しないためのガード）ので `-k` 等で除外する。

AVDとエディタ、複数エディタの同時運用のポート設計は [docs/02-protocol.md](02-protocol.md) 参照。

## キットの更新（導入済みプロジェクトへの再インストール）

新しいキット zip を展開して `install-to-project.ps1 -ProjectPath <プロジェクト>` を**再実行するだけ**。

**更新前のバックアップ:**

- インストーラーが既導入を検知すると、**キット関連領域を丸ごと自動で
  `uapp_e2e/Builds/update-backup-<日時>.zip` に退避**してから更新する（`Builds/` 自体は対象外なので含まれない。
  退避範囲は上書き対象より広く、`e2e-config.json`・自作テスト・`local.json` 等のプロジェクト所有物や
  `.claude/skills/`・`.agents/skills/` 全体も含む＝更新直前の復元点として使える安全側の設計）
- 加えて **VCS の作業ツリーをクリーンにしてから更新する**ことを推奨（更新差分をレビュー・巻き戻しできる）
- **VCS 管理外のファイルは自分で守る**: `uapp_e2e/config/local.json`（環境設定）と
  `uapp_e2e/Builds/`（ジャーニー記録・ビルド成果物）。どちらもインストーラーは触らないが、
  重要なら別途コピーしておく
- キット所有領域（下表）の**既存ファイルに独自改変**を入れている場合は、更新の上書きで消える。
  バックアップzipから差分を回収し、恒久化したい変更はキット側へ還元すること
  （キット所有ディレクトリに**追加**した独自ファイルは、上書きコピーのため削除はされず残る）
- **ローカル改変は自動検知される**: インストーラーは導入時に `uapp_e2e/kit-manifest.json`
  （キット所有ファイルのハッシュ）を記録し、次回更新時に照合して「前回導入後に改変された
  キット所有ファイル」（例: 導入先AIが独自改修した viewer.html）を **[警告] として列挙**する。
  警告が出たら、上書き後にバックアップzipと差分を取り、必要な改変を再適用またはキットへ還元する

マージ作業は不要になるよう、ファイルの所有権を次のように分けている:

| 区分 | 対象 | 更新時の挙動 |
|---|---|---|
| **キット所有** | `Assets/uapp_e2e/E2EBridge/`・`uapp_e2e/driver/e2e_driver/`・`uapp_e2e/scripts/`・`uapp_e2e/docs/`・`uapp_e2e/CLAUDE.md`/`AGENTS.md`/`SETUP.md`/`VERSION`・`.claude/skills/e2e-*`・`.agents/skills/e2e-*`・`.claude/rules/uapp-e2e.md`・`uapp_e2e/driver/tests/test_journey_unit.py`/`test_adb_ui.py`/`test_client_unit.py`/`test_bridge_smoke.py` | **上書き更新**（手を入れない前提。変更したい場合はキット側へ還元する） |
| **プロジェクト所有** | `uapp_e2e/e2e-config.json`・`uapp_e2e/driver/tests/` の自作テスト・`uapp_e2e/config/local.json`・`uapp_e2e/Builds/`（ジャーニー記録含む）・ルート `AGENTS.md`（`-RootAgentsMd` で作成した場合も以後は触らない） | **触らない** |
| **初回のみ生成** | `uapp_e2e/driver/tests/conftest.py`（キット取り込みの1行＋プロジェクト追記領域） | 既存があれば**保持**（フィクスチャの実体は `e2e_driver` パッケージ側にあるため、conftest を更新しなくてもキットの新機能が届く） |

更新後の確認（AI向けランブック）:

1. `uapp_e2e/VERSION` が新しい版数になっていることを確認
2. デバイス不要の健全性チェック: `cd uapp_e2e\driver && pytest tests\test_journey_unit.py -q`
3. conftest.py に `from e2e_driver.pytest_journey import *` の行が残っていることを確認
   （旧キットで導入したプロジェクトはこの行が無いことがある → 先頭に追記する。
   conftest 内に古い client/g フィクスチャ定義が残っていても、同名定義が優先されるだけで害はない）
4. アプリを起動してスモークを1本実行し、接続とタップが通ることを確認

`Assets/uapp_e2e/E2EBridge` はプロトコル互換（`ping.bridge` のバージョン、後方互換の追加のみ）を
保って更新されるため、計装入りビルドの再ビルドは「ブリッジに新機能が必要になったとき」だけでよい。

## アンインストール

導入時に配置される `uapp_e2e\scripts\uninstall.ps1` を実行する:

```powershell
.\uapp_e2e\scripts\uninstall.ps1           # キット所有のみ削除（設定・自作テスト・記録は残す）
.\uapp_e2e\scripts\uninstall.ps1 -Purge    # uapp_e2e\ 全体も削除（ジャーニー記録・バックアップ含む）
```

- **既定**は `Assets/uapp_e2e/`（+ .meta）・`uapp_e2e/` のキット所有部分・`.claude/skills/e2e-*`・
  `.agents/skills/e2e-*`・`.claude/rules/uapp-e2e.md` を削除し、プロジェクト所有物
  （`e2e-config.json`・自作テスト・`conftest.py`・`config/local.json`・`Builds/`）は残す。
  **installer を再実行すれば設定ごと復帰する**ので、試用のやり直しや導入試験の繰り返しに使える
- **`-Purge`** は `uapp_e2e/` を丸ごと削除。ルート `AGENTS.md` は「installer が作成した記録
  （kit-manifest.json のメタ記録）があり、かつ生成時から未編集」の場合に限り削除する
  （1文字でも編集されていれば触らない。ユーザーが元々置いていた同内容のファイルも記録が無いため触らない）
- 他のスキル・ルール（e2e-* 以外）には触らない。空になった `.claude/`・`.agents/` は畳む
- 以下は自動では戻さない（実行後に案内が表示される）:
  1. Scripting Define Symbols の `UAPP_E2E_BRIDGE` 除去（検出状態を表示）
  2. 追加したパッケージが他で不要なら manifest から削除

## 制約・注意

- 有料アセット（NGUI等）はこのキットに含まれない。対応はリフレクションで、対象プロジェクト側のNGUIをそのまま使う
- `Assets/uapp_e2e/E2EBridge` を変更した場合はプロトコル仕様（docs/02）とドライバの同期を保つこと
- 計装ビルドを社外に配布しないこと（デバッグポートが開いた状態のため）


