---
name: e2e-run
description: UnityアプリのE2Eテストを実行し、失敗時は証跡（logcat/スクリーンショット/crashバッファ）から原因を特定して修正まで回す。「E2E実行して」「E2Eテスト回して」「テストが落ちた原因を調べて」等で使用。
---

# E2Eテストの実行と失敗解析

対象プロジェクトの `uapp_e2e/` キットを使って E2E を実行し、失敗時は修正まで回す。
規約の全体像は `uapp_e2e/CLAUDE.md` を先に読むこと。

## 手順

1. エミュレーター確認・起動: `uapp_e2e\scripts\start-emulator.ps1`（起動済みならスキップされる）
2. 計装ビルドが必要か判断:
   - `Assets/` や計装対象コードを変更した → `uapp_e2e\scripts\build-android.ps1`（十数分かかる）
   - テストコードのみの変更 → ビルド不要
3. 実行: `uapp_e2e\scripts\run-e2e.ps1`（テストのみ再実行なら `-SkipInstall`、部分実行は `-PytestArgs "-k <名前>"`）
4. 全パスなら結果を報告して終了

## 失敗時の解析（この順で見る）

1. pytest の失敗メッセージ。`BlockedError` は「誰に遮られたか」のパス付き —
   仕様（先に閉じる操作/`wait_until_hittable`を追加）かバグ（アプリ修正）かを判断
2. `uapp_e2e/Builds/failure/unity-logcat.txt` — マネージド例外のスタックから修正対象を特定
3. `uapp_e2e/Builds/failure/screen.png` — 画像として読み、実際の画面状態を確認
4. **全テストが接続エラーの場合** `uapp_e2e/Builds/failure/crash.txt`（ネイティブクラッシュはUnityタグに出ない）。
   `adb shell pidof <package>` が空ならプロセス死亡。空のままアプリが生きていればエミュレーター疲弊を疑い `adb reboot`
5. dump を再取得して期待とのUI差分を見る

修正 → 手順2から再実行。アプリコードとテストのどちらを直すべきかは、失敗が「実ユーザーにも起きるか」で判断する。
