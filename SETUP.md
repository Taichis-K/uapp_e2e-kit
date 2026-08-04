# SETUP.md — AI向けセットアップランブック

**これは AI エージェント（Claude Code / Codex 等）が読んで実行するためのセットアップ手順書。**
ユーザーから「このプロジェクトにE2E環境をセットアップして」と依頼されたら、この手順を上から実行する。
人間向けの背景説明は docs/05-install-to-project.md にある。

## 前提の確認（最初に必ず）

0. スクリプト実行は **PowerShell 7（pwsh）以降**で行う（Windows PowerShell 5.1 は非対応。
   キットの .ps1 は BOM なし UTF-8 のため 5.1 では日本語が誤解釈され構文エラーになる）。
   **macOS でもそのまま同じ .ps1 を使う**（下の「macOS で使う場合」を先に読むこと）
1. 対象 Unity プロジェクトの場所を特定する（`Assets/` と `ProjectSettings/` がある場所）。
   不明ならユーザーに確認する
2. このキットの入手形態を判別する（直下に `install-to-project.ps1` があるかで見分けられる）:
   - **配布キット zip（uapp_e2e-kit-v*.zip）の展開先、または配布リポジトリの clone** →
     直下の `install-to-project.ps1 -ProjectPath <対象>` で一括配置できる
   - **uapp_e2e 開発リポジトリのチェックアウト**（キット開発者のみ。installer は `scripts\` 配下）→
     `scripts\install-to-project.ps1 -ProjectPath <対象>` で同様に配置できる
   - **既に対象プロジェクト内へ展開済み**（`<プロジェクト>/uapp_e2e/` にこのファイルがある）→ ファイル配置は済み。手順3へ

## macOS で使う場合（**Intel / Apple Silicon の両方で実機検証済み**）

**このキットは Windows で開発している。macOS は Intel Mac（x86_64）と Apple Silicon（arm64）の
両方の実機で一通り検証済み**（2026-08-03: 導入 → EditMode → エディタ直結 E2E → Android ビルド →
エミュレーターのデバイス経路 E2E まで、どちらも全パス。**未確認のまま残っている項目は下表に明記**）。
**arm64 固有の差はセットアップ側だけ**で、スクリプトの分岐は追加不要だった（`/opt/homebrew` の
python も `~/.unity/bin` の arm64 版 Unity CLI もそのまま解決される）。arm64 で要る準備は
**AVD のシステムイメージを arm64 版にすること**（`system-images;android-<API>;google_apis;arm64-v8a`。
x86_64 イメージは動かない）と、**Homebrew の python が PEP 668 の「外部管理」なので
`pip install --user --break-system-packages` が要ること**。APK は既定の ARM64＋X86_64 同梱のままでよい。
**ここに書いていない失敗に当たったら、直したうえでキット作者へ報告してほしい。**

まず PowerShell 7 を入れる（macOS には標準では入っていない）:

```bash
brew install powershell   # Homebrew Core。**旧 powershell/tap は 2026-06 に廃止**され動かない
pwsh -v
```

Homebrew は Microsoft のサポート対象外（公式は「Alternate ways」扱い）。
**公式手段は .pkg**（2026 年 5 月リリース以降は Microsoft の署名・公証済みなので、
ダウンロードして開くだけで入る）。サポート対象の macOS は 14 / 15 / 26（PowerShell 7.6 時点）。

以降のコマンドは Windows と同じ。`pwsh` で起動したシェルから `.ps1` を実行する。

**OS で分かれる判断（実体の探し方・プロセスの見方）は `uapp_e2e/scripts/uapp-platform.ps1` に
集約してある。** mac で「見つからない」「動かない」が出たら、まずそこの解決関数を見ること。
ただし**直す場所がそこだけとは限らない** — 実際の開発でも「helper は正しいのに呼び出し側が
使っていない」「呼び出し側のパス組み立てが Windows 前提」といった不具合が出ている。
分かっている前提と既知の差分:

| 項目 | 実装 | 状態 |
|---|---|---|
| Unity エディタ実体 | `/Applications/Unity/Hub/Editor/<版>/Unity.app/Contents/MacOS/Unity` | Intel / Apple Silicon の両方で実測済み。違う場所なら `config/local.json` の `editorRoots` で上書きできる |
| Unity CLI（`unity`） | **PATH → `~/.unity/bin`（公式 install.sh の配置先）の順**で解決 | mac 版は公式スクリプトで入る: `UNITY_CLI_CHANNEL=beta bash -c "$(curl -fsSL https://public-cdn.cloud.unity3d.com/hub/prod/cli/install.sh)"`（`~/.unity/bin` へ配置・sudo 不要。認証は Unity Hub のログインを流用）。**PATH への追記は対話シェルの rc にしか行われない**が、スクリプト側は既定位置へフォールバックするので非対話シェルでもそのまま使える（`unity` コマンドを直接手で叩くときだけ PATH が要る） |
| Python | `python` → `python3` の順で実行ファイルを探す | **mac は `python` が無く `python3` だけ**という構成が普通（Homebrew はそれしか入れない）。文書中の `python …` の例も、その環境では `python3 …` と読み替える |
| Android SDK | `ANDROID_HOME` → `ANDROID_SDK_ROOT` → `~/Library/Android/sdk` | `emulator` は SDK 配下から直接解決する。**`adb` は PATH 経由で使う**が、PATH に無ければ SDK の `platform-tools` を実行時に PATH へ足す（pytest から呼ばれる Python ドライバも裸の `adb` を使うため、実体を差し替えるのではなく PATH を補う）。どちらも見つからなければ明示エラーで止まる |
| エディタが開いているかの判定 | `ps` のコマンドラインから `-projectPath` を読む | Windows の `Get-CimInstance` 相当が無いため。**ウィンドウタイトル由来の推定は mac では効かない** |
| `Temp/UnityLockfile` の排他判定 | **mac では機能しない** | Unix のファイルロックは助言的で、掴まれていても開けてしまう。判定は残り 2 信号で行う |
| `-Editor` の同時実行ガード（TOCTOU 層） | 名前付き Mutex を**ホスト全体スコープ**（`Global\`）で取る。**OS で分岐しない** | **これは mac 固有の差ではない**（Windows も同じ扱い。issue #24 で合意）。排他は 3 層あり、①`playMode ≠ stopped` で中断 / ②`Test-UnityProjectLocked` / ③名前付き Mutex。**③は①の TOCTOU（2 本が同時に `stopped` を読む窓）を塞ぐ補助層**で、実運用の二重実行は①が止める（①はエディタ自身に問い合わせるので OS のセッション概念と無関係）。**接頭辞なしの名前付き Mutex は `Local\`＝セッション単位**という .NET の仕様のため、素の名前だと Unix では `/tmp/.dotnet/shm/session<セッションID>/`（ID は `getsid()` 由来）に置かれ、**別ターミナルの 2 本が別々のロックを取って③が黙って無効になる**（2026-08-03 に mac で実測して修正）。Windows も RDP・簡易ユーザー切り替え・**セッション 0（タスクスケジューラ）**をまたぐと同型。`Global\` の作成に特権は不要で、Windows 11・非昇格での動作も実測済み。変換は `uapp-platform.ps1` の `Get-UappHostMutexName` |
| HTTP プロキシ配下の Unity CLI | `-UnityCliProxyDisable`（環境変数 `UAPP_E2E_UNITY_CLI_PROXY_DISABLE=1` でも可） | **プロキシがあると `-Editor` 系が一切動かないことがある**。CLI が localhost 宛ての Pipeline 通信までプロキシへ流し、プロキシが 503 を返して `unity status` が `unreachable` になる（ブリッジ側は健全）。`NO_PROXY` / `no_proxy` / `UNITY_NOPROXY` / `unity config proxy --bypass` は**いずれも効かない**（CLI の優先順位は コマンドライン引数 > 環境変数 > 保存設定 > OS 設定）。効くのは CLI 公式の `--proxy-disable` だけなので、`run-e2e.ps1` / `run-unity-tests.ps1` / `unity-editor-status.ps1` にオプトインのスイッチを用意してある。**既定はオフ**（プロキシを黙って無効化しない）。有効にすると認証も直結になるので、セッションが切れているときは先に `unity auth login` を通す |
| `publish-kit.ps1` / `verify-all.ps1` | **Windows 専用** | 配布と全構成一括検証の開発用スクリプト。導入先では使わない |
| 表示メッセージのパス区切り | Windows 表記（`\`）が残っている箇所がある | 実行には影響しない（実際のパス解決は `/` `\` どちらでも通る） |

**mac での立ち上げ順**（失敗したら次へ進まず、その場で直す）:

1. `pwsh -v` … PowerShell 7 が入っていること
2. `./install-to-project.ps1 -ProjectPath <対象>` … ファイル配置（展開したキットの中で実行する。
   ここで転ぶならパス解決の問題）
3. `cd <対象>` … **installer はカレントディレクトリを変えない**。移動しないと以降の相対パスが全部外れる
4. `./uapp_e2e/scripts/unity-editor-status.ps1` … エディタ検出（`ps` 経路の確認。
   Unity を開いた状態と閉じた状態の両方で見ると確度が上がる）
5. `./uapp_e2e/scripts/run-unity-tests.ps1 -Mode EditMode -NoUnityCli` … Unity 実体の解決と batchmode 起動。
   **`-NoUnityCli` を付ける**（付けないと Unity CLI 経由が優先され、mac で一番不安な
   `Unity.app/Contents/MacOS/Unity` の解決を通らないまま緑になる）
6. エディタ直結 E2E（pytest が再生中のエディタへ直接つながることの確認）。
   **これ自体は Unity のバージョンに依存しない** — 依存するのは自動化の導線だけ:
   - `./uapp_e2e/scripts/run-e2e.ps1 -Editor` … シーンを開く〜Play〜終了まで全自動。
     **Unity CLI と `com.unity.pipeline` を使うので Unity 6 以降**（2022.3 では明示エラーで止まる。
     mac に限らない仕様）
   - CLI が無い / Unity 6 未満なら**手動で同じことができる**: エディタで対象シーンを開いて Play →
     別シェルで `cd uapp_e2e/driver` →
     `$env:UAPP_E2E_EDITOR = "1"; pytest tests; Remove-Item Env:\UAPP_E2E_EDITOR`
     （adb 迂回。adb を直接使うテストは `-k` で除外する）。
     **最後の `Remove-Item` を省かない** — 立てっぱなしのまま同じシェルでデバイス経路へ進むと、
     ドライバが adb の使用を明示エラーで拒否する（実機を誤って検証しないための仕様）

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
| インストール済みエディタ | **Windows**: `C:\Program Files\Unity\Hub\Editor\` と `D:\Unity\Hub\Editor\` 等を列挙 / **macOS**: `/Applications/Unity/Hub/Editor/`（実体は `<版>/Unity.app/Contents/MacOS/Unity`）。別の場所に入れている場合は `config/local.json` の `editorRoots` に足す |
| AVD | `emulator -list-avds`。emulator の実体は SDK 配下（**Windows**: `%ANDROID_HOME%\emulator\emulator.exe` / **macOS**: `~/Library/Android/sdk/emulator/emulator`）。SDK は `ANDROID_HOME` → `ANDROID_SDK_ROOT` → OS 既定の順に探し、**目的のツールが実在する候補**を選ぶ |
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
  可能性があれば editorBridgePort を、それぞれ他と重複しない値に）。
  **editorBridgePort は「ホスト側の forward ポート」（`config/local.json` の `bridgePort`）とも別番号にする** —
  デバイス実行が張った adb forward は実行後も残るので、同じ番号だと次にエディタ直結を回したときに
  接続先を奪われる（installer と run-e2e が検査して警告する）
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

結果に **`test_bridge_ping` の PASSED が含まれていることを確認する**（キット同梱の疎通スモーク。
単体テストだけの「N passed」はブリッジに一度も接続していないので、導入検証の証明にならない。
`test_bridge_ping` が SKIPPED のままなら run-e2e 経由で実行できていない）。
**`-PytestArgs "-k …"` や `--deselect` で絞ると、このスモークごと外れて「passed」だけが残る**ので、
導入検証の一発目は絞り込みなしで（`tests` を個別ファイルに変えずに）実行すること。
エディタが別タスクで Play 中の場合は明示エラーで停止する（排他ガード）。
Unity CLI が無い / Unity 6 未満の場合は以下の手動手順で行う。

1. コンパイル確認: 対象バージョンの Unity でバッチ起動し `error CS` が無いこと
2. エディタでも `UAPP_E2E_BRIDGE` define が有効なことを確認して Play
   （define をビルドスクリプトでのみ付与する構成では、一時的に Player Settings の
   Scripting Define Symbols へ追加して再コンパイルさせる）
3. ping（ブリッジは `e2e-config.json` の `editorBridgePort` で待ち受け、`BridgeClient()` が同じ値を自動解決する）:
   ```powershell
   cd uapp_e2e\driver
   # **UAPP_E2E_EDITOR=1 を付ける**: この宣言があるときだけ、ドライバは接続先が本当にエディタかを
   # ping の platform で確かめて、違えば止める（デバイス実行が残した adb forward が同じポートを
   # 握っていると、エディタのつもりで端末のアプリの ping を「疎通できた」と表示してしまう）。
   # **使い終わったら必ず消す** — 残ったままデバイス経路へ進むと adb が明示エラーで拒否される
   $env:UAPP_E2E_EDITOR = "1"
   try { python -c "from e2e_driver import BridgeClient; print(BridgeClient().connect().ping())" }
   finally { Remove-Item Env:\UAPP_E2E_EDITOR -ErrorAction SilentlyContinue }
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