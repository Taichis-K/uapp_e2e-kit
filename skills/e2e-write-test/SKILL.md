---
name: e2e-write-test
description: UnityアプリのE2Eテストを規約に沿って新規作成する。「〜のE2Eテストを書いて」「この画面のテストを追加して」等で使用。必ず実機のUI階層dumpを見てから書く。
---

# E2Eテストの新規作成

`uapp_e2e/driver/tests/` に pytest でテストを書く。規約は `uapp_e2e/CLAUDE.md` 参照。

## 手順（この順番を守る）

1. **対象コードを読む**: テストしたい画面・機能のC#を読み、検証すべき状態（公開フィールド/プロパティ）を把握
1.5 **ジャーニー記録があれば地図として先に読む**: `uapp_e2e/Builds/journey/journey.json` が
   存在すれば、画面id・ボタンpath・hittable・画面遷移・既存テストのカバレッジを最初にここから把握する
   （どの画面に何があるか／どこが未テストかの索引になる。docs/07-viewer.md）。
   **ただし記録は過去のスナップショット**。使うパスは次の手順の生 dump で必ず最終確認する
2. **実物のUI階層を見る**: アプリを起動した状態で dump を取得（推測で書かない）:
   ```powershell
   cd uapp_e2e\driver
   # エディタ再生へ繋ぐときは **必ず** $env:UAPP_E2E_EDITOR = '1' を先に立てる
   # （宣言があるときだけ「本当にこのプロジェクトのエディタか」が検査される。
   #  デバイス経路では立てない — adb の使用が明示エラーになる）
   python -c "from e2e_driver import BridgeClient; import json; print(json.dumps(BridgeClient().connect().dump(), indent=1, ensure_ascii=False))"
   ```
   ノードの `path` / `hittable` / `text` / `ui`（"ngui"ならNGUI要素)を確認。
   **`Selectable`（Button 等）を使わない UI 実装では `dump(probe="all")` にする** —
   既定の `probe="selectable"` では押せる対象が 1 件も出ず「操作待ちではない」と誤読する
3. **テストを書く**。規約:
   - 使用する操作APIは `uapp_e2e/e2e-config.json` の `uiType` に従う
     （`ngui-legacy`→`ngui_tap`系 / `ugui-legacy`→`ugui_tap`系 / それ以外→`tap`系。詳細は SETUP.md の判定表）
   - タップは `g.tap(path)`（hittable検証込み）。レガシーInput構成なら `g.ugui_tap(path)` / `g.ngui_tap(path)`
   - 待機は `g.wait_until_visible / gone / hittable / until`。`time.sleep` は使わない
   - 状態検証は `client.get(path, "コンポーネント名", "プロパティ名")`
   - マルチタッチ（ホールド+タップ、ピンチ）は `g.press/release`（pointerId指定）や `g.pinch`。
     テスト末尾に logcat 例外アサート（`adb.unity_exceptions()` が空）を付ける
   - 3D操作（キャラ移動・カメラ）は `g.drag(x1,y1,x2,y2, hold=秒)`（仮想ジョイスティック合成）。
     座標列の記録再生は再現性が低いので、**目標条件へのフィードバックループ**で書く
     （例: NPCの `resolve().center` で方向を決めて少し歩く→会話ボタンが hittable になるまで繰り返す）。
     長距離移動はデバッグフック（テレポート等）の追加をユーザーに提案するのが本筋
   - **ドラッグで掴む位置を選びたいなら `g.ugui_drag_xy(path, x1,y1, x2,y2)`**（uGUI）。
     `g.ugui_drag` は **path の中心から**始まるので、**中心が別の要素に取られている**
     ScrollRect（中央にスライダーやドロップダウンが載っている）では使えない。
     `path` はイベントの宛先で、位置は x/y が決める（**座標を渡したときは中心のヒットテストをしない** ―
     中心が塞がれていること自体が座標を指定する理由なので）
   - 描画の検証が必要なら `adb.screencap()` で画像を保存し読んで確認
   - テスト間の状態残留に依存しない（前提状態は自分で作るか、順序非依存に書く）
3.5 **アプリの外を触るなら、計装ではなく OS 層を使う**

   **計装（E2EBridge）は Unity アプリの中で動く。** だから
   **外部ブラウザ・システムダイアログ（権限・課金）・ソフトウェアキーボード・他アプリ・
   IMGUI（`OnGUI`）は `dump` にも出ないし `tap` でも押せない。**

   | やりたいこと | Android | iOS |
   |---|---|---|
   | 座標タップ | `adb.ui_tap(...)` | `os_agent.tap(x, y)` |
   | **文字入力** | `adb.ui_type("...")` | **`os_agent.type_text("...", bundle_id=...)`** |
   | システムダイアログ | `adb.ui_tap(text="許可")` | `os_agent.handle_alert("許可")`（省略で候補を列挙） |
   | 他アプリから戻す | — | `os_agent.activate(bundle_id)` |

   ```python
   from e2e_driver import adb, os_agent
   ```

   iOS 側は **`run-ios-e2e.ps1 -OsAgent`** で起動しておくこと（**端末側で
   「設定 → デベロッパ → UI オートメーションを有効」が要る**。無いと約 8 秒で
   `connection was invalidated` になり、**クラッシュレポートも残らない**）。

   **IMGUI は例外的に厄介**: アプリの中にあるのに **EventSystem を通らない**ので
   `ugui_event` では押せず、**`dump` にも出ない**（GameObject ではない）＝**座標も分からない**。
   スクリーンショットを見て座標を決め、**OS 層で押す**しかない。

4. **実行して確認**: `uapp_e2e\scripts\run-e2e.ps1 -SkipInstall -PytestArgs "-k <新テスト名>"`
5. 対象画面がまだアプリに無い・デバッグフックが必要な場合は、アプリ側に最小限のフック
   （画面直行のディープリンク等）を追加する選択肢をユーザーに提案する
