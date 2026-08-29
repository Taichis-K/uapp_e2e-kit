# uapp_e2e — E2Eテストキット（導入先プロジェクト用）

このフォルダは Unity 製 Android アプリの E2E テスト基盤キット。
計装SDK（`Assets/uapp_e2e/E2EBridge/`、`UAPP_E2E_BRIDGE` define 時のみ有効）と、
Pythonドライバ・実行スクリプト一式で構成される。
**このファイルはエージェント共通の運用ガイド**（ファイル名は歴史的経緯で、内容は Claude 専用ではない）。
Claude Code は `.claude/rules/uapp-e2e.md`（導入時に配置される軽量ルール）から、
Codex 等は `uapp_e2e/AGENTS.md`（同）から参照される。
プロジェクト本体の CLAUDE.md を書き換える必要はない。

## よく使うコマンド（このフォルダ＝uapp_e2e/ から実行）

```powershell
.\scripts\start-emulator.ps1                  # AVD起動（config\local.json の avd）
.\scripts\build-android.ps1                   # 計装入りビルド（プロジェクト自動検出）
.\scripts\run-e2e.ps1                         # install→起動→forward→pytest 一括
.\scripts\run-e2e.ps1 -SkipInstall -PytestArgs "-k xxx"   # 部分実行
.\scripts\run-e2e.ps1 -Editor                 # エディタ直結E2E（Unity CLI＋Unity 6以降。ビルド/デバイス/adb不要・
                                              # シーン→解像度→Play→pytest→Play終了まで全自動。既にPlay中なら明示エラー）
.\scripts\run-unity-tests.ps1 -Mode EditMode  # 内側ループ（C#のEditMode/PlayModeテスト。失敗は要約表示）
.\scripts\unity-editor-status.ps1             # **このプロジェクト**のエディタが開いているかを判定（-Json 可）
                                              # Get-Process Unity では判定できない（他プロジェクトと混同する）
.\scripts\close-editor.ps1                    # このプロジェクトのエディタを閉じる（closed を確認するまで待つ）
                                              # 未保存シーンがあれば中断（捨てるなら -Force）
```

**自作の運用スクリプトは `scripts-local\` へ置く**（`scripts\` はキット所有で、更新の上書きと
`uninstall.ps1` の削除対象。自作分を置くと消える）。自作テストの `driver\tests\` と同じ扱い。

**`scripts\` などに自作を置いても改変警告は出ない**（v0.1.14 から。`kit-manifest.json` へは
**キットが実際に配ったファイルだけ**が載る）。**ただし `uninstall.ps1` は今もディレクトリごと消す**
ので、消えて困るものは移すこと。導入・更新のたびに installer が **[情報] で列挙し、
領域ごとの退避先を案内する**:

| 見つかった場所 | 退避先 |
|---|---|
| `uapp_e2e\scripts\` | `uapp_e2e\scripts-local\` |
| `uapp_e2e\docs\` ・ `uapp_e2e\oslayer\` | キットが触らない場所へ |
| `uapp_e2e\driver\e2e_driver\` | `driver\` の外（import 元を変える） |
| `Assets\uapp_e2e\E2EBridge\` | **`Assets\` の中の別フォルダへ**（外へ出すとコンパイルされない） |

**キット所有ファイルを自分が改変したか確かめるには**
`install-to-project.ps1 -ProjectPath <このプロジェクト> -VerifyManifest`（照合のみ・導入はしない。
改変や不在があれば終了コード 1）。**installer は導入先には無い**ので、
**配布 zip を展開した場所から実行する**（詳しくは SETUP.md のトラブル節）。**`kit-manifest.json` のハッシュはテキストの改行を LF に
正規化してから取っている**ので、**素の `Get-FileHash` / `sha256sum` と直接比べても
CRLF を含むファイルは一致しない** — 自前で突き合わせると「ほぼ全件が改変」に見える
（導入先で実際にこの誤読が起きた）。照合は必ず上のコマンドで行う。

### 注入モード（1 つのキットを多数の clone で使い回す）

同一プロダクトの clone が並び、E2E を回す対象が日替わりで変わる運用では、
**キットは 1 か所（ハブ）に置き、対象へは一時的に注入して使う**:

```powershell
.\scripts\inject-to-project.ps1 -TargetProject <clone>      # 注入（計装・define・pipeline・ポート設定だけ）
.\scripts\run-e2e.ps1 -Editor -ProjectPath <clone> -NoProjectTests   # 実行（テストはハブ側）
.\scripts\close-editor.ps1 -ProjectPath <clone>             # 閉じる
.\scripts\inject-to-project.ps1 -TargetProject <clone> -Eject       # 撤去
.\scripts\inject-to-project.ps1 -List                        # 台帳（対象 → スロットとポート）
```

- **対象にはテスト・ドライバ・スクリプトを置かない**（フル導入との違い）。だから
  run-e2e には `-NoProjectTests` を付ける（自作テストが 0 件でも注意行を出さない宣言）
- **ポートは台帳（`config\targets.json`・git 管理外）が対象ごとに割り当てる**。
  重複は「別プロジェクトのエディタを操作する」事故に直結するので、台帳と
  ドライバ側の接続先検査（`UAPP_E2E_EDITOR=1` の platform + project 照合）の**両方**で守る
- **撤去は記録ベース**（対象の `uapp_e2e-inject.json` に入れた物を記録し、それだけを戻す）。
  記録が無い対象を推測で消すことはしない。途中で失敗しても記録は残るのでやり直せる
- 注入は**フル導入済み・既に計装がある対象・非 Unity プロジェクト**を**常に拒否する**
  （`-Force` でも通さない。所有関係が壊れて撤去できなくなるため）。`-Force` で警告に
  落とせるのは**対象のエディタが開いている / 状態を判定できない**場合と、
  **既存の `e2e-config.json` がある**場合（退避して撤去時に戻す）
- 対象の UI 実装に合わせて `-UiType ngui-legacy` 等を渡す（既定 `ugui-nis`。
  生成する `e2e-config.json` に書かれる。`-Orientation` も同様）

複数ターゲット同時: `-DeviceSerial emulator-5556 -HostPort 13335` のように分離する。
エディタ再生中のアプリへは adb 不要で `BridgeClient()` で直接接続できる
（ポートは `e2e-config.json` の `editorBridgePort` を自動解決）。
pytest をエディタ相手に流すには（デバイス/AVD/adb 不要）:

```powershell
cd driver
$env:UAPP_E2E_EDITOR = "1"; pytest tests; Remove-Item Env:\UAPP_E2E_EDITOR
```

対象は adb を直接使わないテストのみ（logcat アサート・adb タップ入りのテストは
エディタ直結モードでは明示エラーになる → `-k` で除外する）。

**Play をまたぐテスト**（新規ユーザーからやり直す等、メモリ上の状態を捨てたい場合）は
1 プロセスの中で完結できる: `.\scripts\restart-editor-play.ps1`（Play 停止 → 再生。
Unity CLI 必須）→ ドライバの `wait_for_bridge(timeout=60)` でブリッジ復帰を待って接続し直す。

```python
from e2e_driver import wait_for_bridge
# （PowerShell 側で .\scripts\restart-editor-play.ps1 を実行した後）
client = wait_for_bridge(timeout=60)   # ポートは e2e-config.json を自動解決
```
サンドボックス環境（Codex 等）で pytest がハング/失敗するときは、一時領域がワークスペース外の
`%TEMP%` に作られ拒否されるのが典型原因 → `--basetemp ..\Builds\pytest-tmp` を付ける（gitignore 済み領域）。

UI階層の確認（**テストを書く前に必ず実物を見る**。例はエディタ再生向け。
デバイスは forward 済みホスト側ポートを `BridgeClient(port=<config\local.json の bridgePort>)` で明示する）:

```powershell
cd driver
$env:UAPP_E2E_EDITOR = '1'   # **必ず宣言する**。宣言があるときだけ、ドライバが
                             # 「本当にこのプロジェクトのエディタか」を確かめる
                             # （platform＋project 照合。宣言が無い接続は検査されない）
try {
  python -c "from e2e_driver import BridgeClient; import json; print(json.dumps(BridgeClient().connect().dump(), indent=1, ensure_ascii=False))"
} finally { Remove-Item Env:\UAPP_E2E_EDITOR -ErrorAction SilentlyContinue }
```

**エディタへ繋ぐときは `UAPP_E2E_EDITOR=1` を付け、使い終わったら必ず消す**:

```powershell
$env:UAPP_E2E_EDITOR = '1'
try   { python -c "..." }
finally { Remove-Item Env:\UAPP_E2E_EDITOR -ErrorAction SilentlyContinue }
```

この宣言があるときだけ、ドライバは**接続先が本当にエディタか**を ping の `platform` で確かめ、
違えば `WrongBridgeTargetError` で止める（デバイス実行が残した `adb forward` が同じポートを
握っていると、エディタのつもりで端末のアプリを検証してしまうため）。
**宣言が無い接続は検査されない** — `adb` の使用ガードと同じ約束。
**立てっぱなしにしない**: 残ったまま同じシェルでデバイス経路へ進むと、
ドライバが adb の使用を明示エラーで拒否する（実機を誤って検証しないための仕様）。


ジャーニー記録（画面把握・遷移・カバレッジの可視化 → 自己完結HTMLレポート）は
**run-e2e.ps1 が既定で `Builds\journey\` に記録し、テスト後に `Builds\journey\report.html` を自動更新する**
（journey フィクスチャを使うテストが対象。無効化は `-NoJourney`、出力先変更は `-JourneyDir`）。
pytest 直叩きで記録する場合:

```powershell
cd driver
pytest tests --journey ..\Builds\journey          # または環境変数 UAPP_E2E_JOURNEY_DIR
python -m e2e_driver.journey ..\Builds\journey    # → report.html 生成（詳細: docs/07-viewer.md）
```

エージェント開発ダッシュボード（任意・別ツール）を使う場合のみ、テスト/E2E/ビルドの結果が
`.agent-status\` へ1行ずつ記録される（`scripts\emit-status.ps1`）。**そのフォルダが無ければ何もしない**
ので、使わない環境では意識しなくてよい（詳細: docs/ai-loop.md）。

## 設定

- `e2e-config.json` — プロジェクト仕様（package / tests / 画面向き / devicePort / editorBridgePort）。git管理。
  同一デバイスに計装アプリが複数あるときは devicePort をアプリごとに分ける
- `config/local.json` — 実行環境（AVD名 / ホスト側ポート / Unityエディタの場所）。**git管理外**。無ければ `local.sample.json` をコピーして作る

## E2Eテスト規約（AI向け・必読）

1. **dump を見てから書く**。コードから推測した名前でテストを書かない。
   `Builds/journey/journey.json`（ジャーニー記録）があれば**画面・ボタン・カバレッジの索引**として
   先に読んでよいが、過去のスナップショットなので使うパスは生 dump で最終確認する。
   **`Selectable`（Button 等）を使わない UI 実装では `dump(probe="all")` を使う** —
   既定の `probe="selectable"` は Selectable 持ちしか hittable 判定しないため、
   透明 Image や独自ボタンだけの画面では**押せる対象が 1 件も出ず**、
   「操作待ちではない」と誤読する（導入先で実際に踏まれた）
2. タップは `Gestures.tap`（hittable検証込み）。`BlockedError` は遮蔽者のパスを含む —
   仕様（先に閉じる/`wait_until_hittable`）かバグ（アプリ修正）かをそこから判断する
3. 待機は `wait_until_visible / gone / hittable / until` を使う。`time.sleep` は
   「待てる条件が存在しない」場合（物理値の安定待ち・「何も起きない」ことの確認）のみ例外とし、理由をコメントに書く
4. **UI を経由しない入力は `Keyboard` / `Mouse` / `Gamepad`**（`tap(path)` では動かせない）。
   キー・パッドのボタン・マウスクリックを直接見ているコードが対象。専用の仮想デバイスへ注入するので、
   PC に実機が刺さっていても混ざらない（`client.input_devices()` で接続状況を確認できる）。
   **仮想デバイスは種別ごとに初回注入時に生成される**ので、注入前の `devices` に出ないのは正常
   （生成済みかは `virtualDevices` の `created`。注入前に `devices` を名前で引くと `KeyError` になる）。
   テスト後は `client.input_reset()`（注入に使うデバイスが無効化されたままなら再有効化する
   ＝復旧路も兼ねる。実機のキーボード・マウス・パッドには触らない）。
   **`input_reset()` は押されたままのタッチポインタも解放する**（`releasedPointers`）。
   **異常終了したときこそこれを打つ** ― 常駐スクリプトを kill すると押下が残り、
   以後のタップが全部 `POINTER_ALREADY_DOWN` で落ちる。
   **症状は「特定のボタンが効かない」に見える**ので、アプリ側を疑う前にまず解放すること。
   エディタ再生では Game view のフォーカスに注入が左右されないよう初回注入時に Input System 設定を
   自動で切り替える（再生終了時に復元。適用状態は `input_devices` の `editorFocusOverride`）。
   レガシー入力バックエンドのみの構成では `INPUT_BACKEND_LEGACY` で明示的に失敗する
5. **NGUI のレガシーInput構成では `ngui_tap / ngui_press / ngui_release`**（`pointer_*` は届かない）。
   構成は `ping` の `ngui` と、NGUI が `Input.touchCount` を直読みしているかで判断
6. マルチタッチテストには logcat 例外アサート（`adb.clear_logcat()` → 操作 → `adb.unity_exceptions()` 空）を付ける
7. 描画の検証は `adb.screencap()` で画像を取得して読む（エディタ直結では journey のスクリーンショットを見る）。
   **撮影は「OS 層優先・計装は保険」の 2 段構え** — `adb screencap` は画面に出ているものをそのまま残せるが、計装の `client.screenshot()` は **Unity の描画しか写らない**（WebView・ネイティブダイアログ・ソフトキーボードは欠ける）。後者は既定オフで、`UAPP_E2E_BRIDGE_SCREENSHOT=1` を宣言したときだけ使える（縮小は `UAPP_E2E_BRIDGE_SCREENSHOT_MAX_WIDTH`）

## 失敗解析の優先順位

0. **ジャーニー記録の回帰フラグ**: `Builds/journey/journey.json` の `"regressed": true`
   （前回成功→今回失敗）を見つけたら、直近の自分の変更が壊した可能性を最優先で調査する。
   まず再実行して再現性を確認し、一時的要因（サーバー・タイミング）と切り分ける
1. pytest の失敗メッセージ
2. `Builds/failure/unity-logcat.txt`（マネージド例外スタック）
3. `Builds/failure/screen.png`（画像として読む）
4. **インストールで転んでいないか**（テスト失敗に見える）。空き容量・署名不一致が典型。
   run-e2e が理由を翻訳して出すので、その案内に従う（`adb shell df /data` で空きを確認）
5. **全テスト接続エラーなら `Builds/failure/crash.txt`**（ネイティブクラッシュはUnityタグに出ない）。
   `adb shell pidof <package>` が空ならプロセス死亡
6. dump を再取得して期待とのUI差分を見る
7. **エディタ直結で Unity CLI の呼び出しが失敗した**とき、run-e2e は生の応答を
   `Builds/failure/unity-cli-raw.txt` へ自動保存する。まずそれを見る。残るのは 2 種類:
   - **JSON にできなかった応答**（`ConvertFrom-Json` のエラーメッセージは原因と無関係な
     見た目になる — 文字化けで閉じ引用符が食われる・版差でヘルプ文が混ざる等）
   - **分類できなかった CLI エラー**（`[未知のエラー文]` のタグ付き）。run-e2e は失敗を
     「待てば直る（transient）／待っても直らない／分類できない」に分け、**分類できないものは
     原文を残して即失敗する**。**ここに出た文言は報告してほしい** — 待つべきエラーを
     取りこぼしていた場合、その文言を分類に足すことで直せる（issue #38 はまさにその型で、
     `Network error:` を「待っても直らない」と誤分類していた）
   **このファイルは 1 回の実行の先頭で切り詰められ、以後は追記される**（同じ走行の複数の
   呼び出しが並ぶ。前回の走行とは混ざらない）
8. **出力を丸ごとファイルへ残したいときは `Start-Transcript` か `6>&1`**。
   キットの進捗行は `Write-Host`（情報ストリーム）なので、**`2>&1 | Tee-Object` では
   取れない**（pytest の標準出力だけが残り、キット側の行は端末にしか出ない）。
   導入先で実際に踏まれた。**利用者にログを送ってもらう場面で `Tee-Object` を勧めないこと**

**自作の PowerShell スクリプトから `unity cmd` を直接叩くときは、先頭で文字コードを明示する**。
コンソールを持たない起動（`Start-Process -RedirectStandardOutput` 等。AI からの detached 実行が典型）
では出力の符号化が OEM（日本語環境なら cp932）に落ち、**日本語を含む応答だけ** JSON が壊れる
（ASCII 応答では再現せず、手で叩くと正常なので誤診しやすい。キット同梱スクリプトは対処済みだが、
自作スクリプトには自分で入れる必要がある）:

```powershell
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
```

**結果の読み方（3 つ）**:
**赤いとき＝測り方を疑う**（判定式の戻り値でなく出力そのものを見る）/
**緑のとき＝測った対象を疑う**（何件・どのファイルを測ったのかを出力で確かめる。
「偽の緑」は毎回、測っていないものを測ったつもりになっている形だった）/
**どちらとも言えないとき＝直近の変更を証拠なしに犯人にしない**
（疑う順番としては正しいが、条件を 1 つずつ外して再現を取るまで断定しない）。

**切り分けでやってはいけないこと（エディタ直結）**: `InputSystem.DisableDevice(...)` での
デバイス無効化と、`IPointerDownHandler` 等のイベントハンドラの直接呼び出し。どちらも
**その Play セッションの注入が壊れたまま戻らなくなる**（実マウスの干渉排除やハンドラ疎通確認の
つもりでも使わない）。壊してしまったら `client.input_reset()` が**注入に使うデバイス**
（仮想デバイスと Touchscreen）を再有効化する。実機のキーボード・マウス・パッドは戻さないので、
それらを止めてしまった場合と、それでも戻らない場合は Play を再起動する

## 制約

- **macOS は Intel（x86_64）と Apple Silicon（arm64）の両方の実機で検証済み（2026-08-03）**（キット開発は Windows）。
  スクリプトは同じ .ps1 を pwsh 7 で動かす。
  OS で分かれる判断（実体の探し方・プロセスの見方）は `scripts/uapp-platform.ps1` に集約してあるので、
  mac で動かないときは**まずそこの解決関数を見る**。ただし**直す場所がそこだけとは限らない**
  （helper は正しいのに呼び出し側が使っていない、という不具合が実際に出ている）。
  前提と既知の差分は [SETUP.md](SETUP.md) の「macOS で使う場合」。
  **パス結合に `Join-Path $dir "A\B"` と書かない**（mac では `\` が区切りにならない）。
  代わりに `Join-UappPath $dir "A\B"` を使う（両方の区切りを解釈する）
- **対応プラットフォームは Android（実機・エミュレーター）・エディタ直結・iOS（macOS のみ）**。
  iOS は 0.1.9 で統合された（`build-ios.ps1` / `run-ios-e2e.ps1`。シミュレータ・実機とも）。
  使う前に [SETUP.md](SETUP.md) の「iOS で使う場合」の制約表を**設計前に**読むこと —
  特に **iOS のアプリ外（外部ブラウザ・システムダイアログ）の操作は、計装では不可・
  同梱の OS レイヤーエージェント（`run-ios-e2e.ps1 -OsAgent`）でも座標タップとスクショまでしか
  検証されていない**（Android は同梱の `adb` uiautomator 経由で文字入力まで可能）。
  **外部ブラウザ認証を含む導線は iOS では検証が止まりうる**前提で設計する
- **`run-ios-e2e.ps1 -OsAgent` が `pairingState=…` で止まったら [docs/09-ios16-osagent.md](docs/09-ios16-osagent.md)**。
  CoreDevice が担当しない実機（表示は `unsupported` ではなく **`未登録`** になることがある）でも、
  go-ios を自分で用意すれば OS エージェントを動かせる（**go-ios は同梱していない**）。
  **ガードは外さない** — 宛先に出るようになっても `xcodebuild test` は同じ文言で落ちる
- **計装が撮るスクショ（`client.screenshot()`）は Unity の描画しか写らない**。
  WebView・ネイティブダイアログ・ソフトキーボード・広告 SDK のビューは欠ける。
  **画面に出ているものを忠実に残すなら OS 層**（Android は `adb screencap`。ジャーニー記録は
  既定でこちらを使う）。計装側の撮影は**撮る瞬間にアプリのフレームコストがかかる**ため既定オフ
  （`UAPP_E2E_BRIDGE_SCREENSHOT=1` で有効化）
- 計装は `UAPP_E2E_BRIDGE` define のあるビルドのみ。**本番ビルドに define を付けない**
- `Assets/uapp_e2e/E2EBridge/` を変更したら `docs/02-protocol.md` と `driver/e2e_driver/` を同期
- 計装入りビルドを社外配布しない

## スキル

導入時に同一内容が `.claude/skills/`（Claude Code）と `.agents/skills/`（Codex CLI v0.94.0 以降）へ
配置されている（installer の `-Agents claude|codex|both` 指定に応じて片方のみの場合もある。
足りない側は installer を該当値で再実行すれば追加できる）。
呼び出しは Claude Code が `/e2e-setup` 等のスラッシュコマンド、
Codex が `$e2e-setup` 等の `$` 言及（または `/skills` から選択）:

- `e2e-setup` — 環境セットアップ・修復（`SETUP.md` ランブックを実行）
- `e2e-run` — E2E実行＋失敗解析ループ（証跡の読み方の手順込み）
- `e2e-write-test` — 規約に沿ったE2Eテストの新規作成（dumpを見てから書く手順）
- `e2e-dump` — 実行中アプリのUI階層取得と要約

セットアップが未完了・壊れている場合は [SETUP.md](SETUP.md) が入口。

## 開発の回し方（重要）

**ロジックは内側ループ（EditMode/PlayModeテスト、秒〜分）で検証し、E2E（十数分/回）は
導線・入力・描画に絞る。** エディタ再生への直接接続はビルド不要の高速な中間ループとして使える。
詳細な手順・判断基準は [docs/ai-loop.md](docs/ai-loop.md)。

詳細: [docs/02-protocol.md](docs/02-protocol.md)（プロトコル仕様）/ [docs/ai-loop.md](docs/ai-loop.md)（AIループ開発）/ [docs/05-install-to-project.md](docs/05-install-to-project.md)（導入・アンインストール）

