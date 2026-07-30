# SETUP.md — AI向けセットアップランブック

**これは AI エージェント（Claude Code / Codex 等）が読んで実行するためのセットアップ手順書。**
ユーザーから「このプロジェクトにE2E環境をセットアップして」と依頼されたら、この手順を上から実行する。
人間向けの背景説明は docs/05-install-to-project.md にある。

## 前提の確認（最初に必ず）

0. スクリプト実行は **PowerShell 7（pwsh）以降**で行う（Windows PowerShell 5.1 は非対応。
   キットの .ps1 は BOM なし UTF-8 のため 5.1 では日本語が誤解釈され構文エラーになる）
1. 対象 Unity プロジェクトの場所を特定する（`Assets/` と `ProjectSettings/` がある場所）。
   不明ならユーザーに確認する
2. このキットの入手形態を判別する（直下に `install-to-project.ps1` があるかで見分けられる）:
   - **配布キット zip（uapp_e2e-kit-v*.zip）の展開先、または配布リポジトリの clone** →
     直下の `install-to-project.ps1 -ProjectPath <対象>` で一括配置できる
   - **uapp_e2e 開発リポジトリのチェックアウト**（キット開発者のみ。installer は `scripts\` 配下）→
     `scripts\install-to-project.ps1 -ProjectPath <対象>` で同様に配置できる
   - **既に対象プロジェクト内へ展開済み**（`<プロジェクト>/uapp_e2e/` にこのファイルがある）→ ファイル配置は済み。手順3へ

## 手順

### 1. ファイル配置（installer がある場合）

```powershell
# 配布キット / clone から:              .\install-to-project.ps1 -ProjectPath <対象プロジェクト>
# 開発リポジトリから（キット開発者）:   .\scripts\install-to-project.ps1 -ProjectPath <対象プロジェクト>
```

これで `Assets\uapp_e2e\E2EBridge`・`uapp_e2e\`一式・AIエージェント導線が配置される。
導線は `-Agents claude|codex|both`（既定 both）で選択できる: claude=`.claude\skills\`+`.claude\rules\`、
codex=`.agents\skills\`+`uapp_e2e\AGENTS.md`。後から追加したくなったら該当値で再実行すればよい
（再実行安全・既配置分の自動削除はしない）。
Codex ユーザーでルート `AGENTS.md` が無いプロジェクトは `-RootAgentsMd` を付けると
発見用ポインタも新規作成される（既存の AGENTS.md は変更されない）。

### 2. 環境の自動検出（推測せず、必ず実物から読む）

| 項目 | 取得方法 |
|---|---|
| Unityバージョン | `<プロジェクト>/ProjectSettings/ProjectVersion.txt` の `m_EditorVersion` |
| package（applicationId） | `ProjectSettings/ProjectSettings.asset` の `applicationIdentifier` の Android 値 |
| 画面向き | 同ファイルの `defaultScreenOrientation`（0=Portrait, 4=AutoRotation, 2/3=Landscape系） |
| 入力方式 | 同ファイルの `activeInputHandler`（0=レガシーのみ→**Bothへの変更が必要**、1=NIS、2=Both） |
| NGUI の有無 | `Assets/` 配下に `UICamera.cs` があるか（Glob） |
| NGUIの入力読み | `UICamera.cs`（または入力ラッパー）が `Input.touchCount` を直読み→レガシー構成 |
| インストール済みエディタ | `C:\Program Files\Unity\Hub\Editor\` と `D:\Unity\Hub\Editor\` 等を列挙 |
| AVD | `emulator -list-avds`（`%ANDROID_HOME%\emulator\emulator.exe`） |
| カスタムActivity | `Assets/Plugins/Android/AndroidManifest.xml` があれば MAIN/LAUNCHER の activity 名。**Unity 6 系は既定が `UnityPlayerGameActivity`（GameActivity方式）の場合がある** — 初回インストール後に `adb shell cmd package resolve-activity --brief <package>` で実際の値を確認するのが確実 |

### 2.5 構成判定とセットアップ分岐（検出結果からここで決める）

検出した「UIフレームワーク × 入力方式」で以降のセットアップと使用APIが変わる。
判定結果は `uiType` として e2e-config.json に記録する。

| 検出結果 | uiType | セットアップ上の追加作業 | テストで使う操作API |
|---|---|---|---|
| uGUI + New Input System | `ugui-nis` | なし（標準） | `tap / press / pinch`（Touchscreen注入） |
| uGUI + レガシーのみ | `ugui-legacy` | Input Handling を Both に。**EventSystemが`StandaloneInputModule`のままだと注入タップはUIに届かない** → `InputSystemUIInputModule`への切替をユーザーに提案（通常挙動は変わらない）。切替不可なら操作は adb 単点タップに限定 | 切替後: `tap`系 / 切替不可: `adb.input_tap_unity_coords` |
| NGUI + NIS配線済み（入力ラッパーがMouse/EnhancedTouchを読む） | `ngui-nis` | なし | `tap / press / pinch` ＋ `ngui_*` も可 |
| NGUI + レガシー読み（UICameraが`Input.touchCount`直読み） | `ngui-legacy` | Input Handling を Both に（E2EBridgeのコンパイルに必要。NGUIの挙動は不変） | `ngui_tap / ngui_press / ngui_release`（**`pointer_*`は届かない**）＋実入力検証は adb タップ |
| uGUI と NGUI が混在 | `mixed` | 上記の該当分岐を両方適用 | 要素の `ui` フィールド（dump）で使い分け |

判定に自信が持てない場合（入力ラッパーが独自実装等）は、根拠（該当コードの抜粋）を添えて
ユーザーに確認してから進める。

### 3. 設定ファイルの生成

検出結果を反映して作成・編集する:

- `uapp_e2e/e2e-config.json` — package / activity / orientation / tests / devicePort / editorBridgePort / **uiType（手順2.5の判定結果）**
  （同一デバイスに他の計装アプリが入る可能性があれば devicePort を、複数プロジェクト並行開発の
  可能性があれば editorBridgePort を、それぞれ他と重複しない値に）
- `uapp_e2e/config/local.json` — `local.sample.json` をコピーし、検出した AVD 名・エディタルートを記入。
  対象バージョンのエディタが見つからなければ**ユーザーに報告して指示を待つ**（勝手にインストールしない）。
  AVD が列挙できない場合（サンドボックスで Android SDK を読めない等）は推測で埋めず、
  **暫定値を使ったことを明記してユーザーに実在の AVD 名を確認する**

### 4. プロジェクト設定の変更（変更は最小限・すべて可逆）

1. `Packages/manifest.json` に追加（未導入の場合のみ。既存 Newtonsoft DLL があればパッケージは追加しない）:
   - `com.unity.inputsystem`（2022.3系: "1.7.0" / Unity 6系: "1.14.0" 以降。**そのUnityバージョンに存在する版か注意**）
   - `com.unity.nuget.newtonsoft-json`: "3.2.1"
2. `activeInputHandler` が 0 のプロジェクトは 2（Both）へ（ProjectSettings.asset を直接編集可。レガシー入力の挙動は変わらない）
3. テスト用ビルドへの `UAPP_E2E_BRIDGE` define 付与:
   - 自前ビルドスクリプトがある → そこに define 追加処理を組み込む（docs/05 のスニペット）
   - 無い → Player Settings の Scripting Define Symbols へ追加（本番ビルド前に外す運用をユーザーに確認）
4. `.gitignore` に `uapp_e2e/config/local.json` と `uapp_e2e/Builds/` を追加
5. `.claude/rules/uapp-e2e.md` と `uapp_e2e/AGENTS.md` が配置されていることを確認（installer が配置する。
   これらが `uapp_e2e/CLAUDE.md` への参照導線となるため、**プロジェクト本体の CLAUDE.md は書き換えない**。
   既存のルート AGENTS.md への自動追記もしない — 統合はユーザーに提案し判断を仰ぐ）

### 5. 検証（ここまでの成果を必ず実際に動かして確認）

**まず 5a（エディタ再生・数分）で疎通させてから 5b（APKビルド・十数分）へ進む。**
計装のコンパイル・NGUI検出・プロトコル疎通は 5a で全部検証でき、失敗時の切り分けもビルドと分離できる。

#### 5a. エディタ再生で疎通（数分・デバイス/adb 不要）

**Unity CLI（v1.0.0-beta.3+）がインストール済みで対象が Unity 6 以降なら、1コマンドで完結する**
（シーンオープン→Game view解像度設定→Play開始→pytest→Play終了まで全自動。人手でのPlay操作は不要）:

```powershell
.\uapp_e2e\scripts\run-e2e.ps1 -Editor
# adb を使うテストがある場合は除外: -PytestArgs "--deselect tests/xxx.py::test_yyy"
```

エディタが別タスクで Play 中の場合は明示エラーで停止する（排他ガード）。
Unity CLI が無い / Unity 6 未満の場合は以下の手動手順で行う。

1. コンパイル確認: 対象バージョンの Unity でバッチ起動し `error CS` が無いこと
2. エディタでも `UAPP_E2E_BRIDGE` define が有効なことを確認して Play
   （define をビルドスクリプトでのみ付与する構成では、一時的に Player Settings の
   Scripting Define Symbols へ追加して再コンパイルさせる）
3. ping（ブリッジは `e2e-config.json` の `editorBridgePort` で待ち受け、`BridgeClient()` が同じ値を自動解決する）:
   ```powershell
   cd uapp_e2e\driver
   python -c "from e2e_driver import BridgeClient; print(BridgeClient().connect().ping())"
   ```
4. `ping` 応答の `ngui` が手順2の検出と一致することを確認
5. pytest まで流す場合はエディタ直結モード（adb を迂回）で:
   ```powershell
   $env:UAPP_E2E_EDITOR = "1"; pytest tests; Remove-Item Env:\UAPP_E2E_EDITOR
   ```
   adb を直接使うテスト（logcat アサート・adb タップ）はこのモードでは明示エラーになる。
   その場合は `-k` で除外して流し、除外分は 5b で検証する。
   **サンドボックス環境（Codex 等）で pytest がハング/失敗する場合**: pytest の一時領域が
   ワークスペース外の `%TEMP%` に作られ書き込み拒否されるのが典型原因。
   `--basetemp ..\Builds\pytest-tmp`（`driver\` から実行時。Builds は gitignore 済み）を付けて回避する

#### 5b. APK ビルドで実機/エミュレーター検証（十数分）

**Android を使わない運用（エディタ直結E2Eだけで回す）なら 5b は行わない。**
その場合は 5a の完了をもって導入完了とし、次のように扱う（installer に `-Mode editor` を渡すと
残手順の表示もこの前提になる）:

| 項目 | エディタ専用運用での扱い |
|---|---|
| `UAPP_E2E_BRIDGE` define | **Build Settings で選んでいるプラットフォーム**に付ける（Android のままでも Standalone でもよい。エディタはアクティブなターゲットの define でコンパイルする） |
| `e2e-config.json` の `package` / `activity` | 使わないので空でよい（adb を使わないため） |
| `config\local.json` の `avd` | 不要 |
| 実行コマンド | `uapp_e2e\scripts\run-e2e.ps1 -Editor` と `run-unity-tests.ps1 -Mode EditMode -Editor` |

1. ビルド: `uapp_e2e\scripts\build-android.ps1`（初回はIL2CPPで10分超）
2. エミュレーター起動 → `uapp_e2e\scripts\run-e2e.ps1`（テスト未作成なら ping 疎通のみ。
   5a で Player Settings に足した define をビルドスクリプト付与へ戻す場合はここで外す）
3. 結果（検出した構成・変更したファイル一覧・疎通結果）をユーザーに報告

### 6. 最初のテスト作成（ユーザーが望む場合）

`e2e-write-test` スキル（`.claude/skills/` および `.agents/skills/` の `e2e-write-test/`）の手順に従う。
**必ず dump で実物の UI 階層を見てから書く。**

## トラブル時

`uapp_e2e/CLAUDE.md` の失敗解析手順と `docs/05-install-to-project.md` のトラブルシューティングを参照。
判断に迷う変更（プロジェクト設定の書き換え等）は実行前にユーザーへ提示すること。

## ライセンスと商標

このキットは **MIT ライセンス**（同梱の `LICENSE`）。計装コード・ドライバ・スクリプトはすべて
このキットの著作物で、有償アセットや伝播性ライセンスのコードは含まない。

- NGUI 連携（`NguiAdapter`）は**リフレクションで型名を参照するだけ**で、NGUI のコードは同梱しない。
  NGUI を使うかどうかは導入先プロジェクトの資産とライセンスに従う
- Unity・Input System・Newtonsoft.Json・Android SDK・Python 等は**再配布していない**。
  それぞれの提供元から導入し、各ライセンス・利用規約に従うこと
- Unity は Unity Technologies、Android は Google LLC、NGUI は各権利者の商標。
  **このキットは Unity Technologies 公式の製品ではなく、提携・承認も受けていない**