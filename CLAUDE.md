# uapp_e2e — E2Eテストキット（導入先プロジェクト用）

このフォルダは Unity 製 Android アプリの E2E テスト基盤キット。
計装SDK（`Assets/uapp_e2e/E2EBridge/`、`UAPP_E2E_BRIDGE` define 時のみ有効）と、
Pythonドライバ・実行スクリプト一式で構成される。
**`.claude/rules/uapp-e2e.md`（導入時に配置される軽量ルール）から参照される。
プロジェクト本体の CLAUDE.md を書き換える必要はない。**

## よく使うコマンド（このフォルダ＝uapp_e2e/ から実行）

```powershell
.\scripts\start-emulator.ps1                  # AVD起動（config\local.json の avd）
.\scripts\build-android.ps1                   # 計装入りビルド（プロジェクト自動検出）
.\scripts\run-e2e.ps1                         # install→起動→forward→pytest 一括
.\scripts\run-e2e.ps1 -SkipInstall -PytestArgs "-k xxx"   # 部分実行
```

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

UI階層の確認（**テストを書く前に必ず実物を見る**。例はエディタ再生向け。
デバイスは forward 済みホスト側ポートを `BridgeClient(port=<config\local.json の bridgePort>)` で明示する）:

```powershell
cd driver
python -c "from e2e_driver import BridgeClient; import json; print(json.dumps(BridgeClient().connect().dump(), indent=1, ensure_ascii=False))"
```

ジャーニー記録（画面把握・遷移・カバレッジの可視化 → 自己完結HTMLレポート）は
**run-e2e.ps1 が既定で `Builds\journey\` に記録し、テスト後に `Builds\journey\report.html` を自動更新する**
（journey フィクスチャを使うテストが対象。無効化は `-NoJourney`、出力先変更は `-JourneyDir`）。
pytest 直叩きで記録する場合:

```powershell
cd driver
pytest tests --journey ..\Builds\journey          # または環境変数 UAPP_E2E_JOURNEY_DIR
python -m e2e_driver.journey ..\Builds\journey    # → report.html 生成（詳細: docs/07-viewer.md）
```

## 設定

- `e2e-config.json` — プロジェクト仕様（package / tests / 画面向き / devicePort / editorBridgePort）。git管理。
  同一デバイスに計装アプリが複数あるときは devicePort をアプリごとに分ける
- `config/local.json` — 実行環境（AVD名 / ホスト側ポート / Unityエディタの場所）。**git管理外**。無ければ `local.sample.json` をコピーして作る

## E2Eテスト規約（AI向け・必読）

1. **dump を見てから書く**。コードから推測した名前でテストを書かない。
   `Builds/journey/journey.json`（ジャーニー記録）があれば**画面・ボタン・カバレッジの索引**として
   先に読んでよいが、過去のスナップショットなので使うパスは生 dump で最終確認する
2. タップは `Gestures.tap`（hittable検証込み）。`BlockedError` は遮蔽者のパスを含む —
   仕様（先に閉じる/`wait_until_hittable`）かバグ（アプリ修正）かをそこから判断する
3. 待機は `wait_until_visible / gone / hittable / until` を使う。`time.sleep` は
   「待てる条件が存在しない」場合（物理値の安定待ち・「何も起きない」ことの確認）のみ例外とし、理由をコメントに書く
4. **NGUI のレガシーInput構成では `ngui_tap / ngui_press / ngui_release`**（`pointer_*` は届かない）。
   構成は `ping` の `ngui` と、NGUI が `Input.touchCount` を直読みしているかで判断
5. マルチタッチテストには logcat 例外アサート（`adb.clear_logcat()` → 操作 → `adb.unity_exceptions()` 空）を付ける
6. 描画の検証は `adb.screencap()` で画像を取得して読む

## 失敗解析の優先順位

0. **ジャーニー記録の回帰フラグ**: `Builds/journey/journey.json` の `"regressed": true`
   （前回成功→今回失敗）を見つけたら、直近の自分の変更が壊した可能性を最優先で調査する。
   まず再実行して再現性を確認し、一時的要因（サーバー・タイミング）と切り分ける
1. pytest の失敗メッセージ
2. `Builds/failure/unity-logcat.txt`（マネージド例外スタック）
3. `Builds/failure/screen.png`（画像として読む）
4. **全テスト接続エラーなら `Builds/failure/crash.txt`**（ネイティブクラッシュはUnityタグに出ない）。
   `adb shell pidof <package>` が空ならプロセス死亡
5. dump を再取得して期待とのUI差分を見る

## 制約

- 計装は `UAPP_E2E_BRIDGE` define のあるビルドのみ。**本番ビルドに define を付けない**
- `Assets/uapp_e2e/E2EBridge/` を変更したら `docs/02-protocol.md` と `driver/e2e_driver/` を同期
- 計装入りビルドを社外配布しない

## スキル

導入時に `.claude/skills/` へ以下が配置されている（スラッシュコマンドで呼び出し可能）:

- `/e2e-setup` — 環境セットアップ・修復（`SETUP.md` ランブックを実行）
- `/e2e-run` — E2E実行＋失敗解析ループ（証跡の読み方の手順込み）
- `/e2e-write-test` — 規約に沿ったE2Eテストの新規作成（dumpを見てから書く手順）
- `/e2e-dump` — 実行中アプリのUI階層取得と要約

セットアップが未完了・壊れている場合は [SETUP.md](SETUP.md) が入口。

## 開発の回し方（重要）

**ロジックは内側ループ（EditMode/PlayModeテスト、秒〜分）で検証し、E2E（十数分/回）は
導線・入力・描画に絞る。** エディタ再生への直接接続はビルド不要の高速な中間ループとして使える。
詳細な手順・判断基準は [docs/ai-loop.md](docs/ai-loop.md)。

詳細: [docs/02-protocol.md](docs/02-protocol.md)（プロトコル仕様）/ [docs/ai-loop.md](docs/ai-loop.md)（AIループ開発）/ [docs/05-install-to-project.md](docs/05-install-to-project.md)（導入・アンインストール）

