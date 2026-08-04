---
name: e2e-dump
description: 実行中のUnityアプリのUI階層をdumpして見やすく要約する。「今の画面のUI構造を見せて」「dumpして」「この画面に何があるか調べて」等で使用。
---

# UI階層のdumpと要約

実行中のアプリ（エミュレーター or エディタ再生）から UI 階層を取得して要約する。

## 手順

1. 接続先を判断:
   - エディタ再生中: 引数不要（`BridgeClient()` が `uapp_e2e/e2e-config.json` の `editorBridgePort` を自動解決）
   - エミュレーター/実機: `adb forward` 済みのホストポート（`uapp_e2e/config/local.json` の `bridgePort`）を
     `BridgeClient(port=<ポート>)` で明示
2. 取得。**エディタ用とデバイス用でコマンドが違う**（混ぜない）:

   **エディタ再生へ繋ぐ場合** — `UAPP_E2E_EDITOR=1` を付ける。この宣言があるときだけ
   接続先が本当にエディタか検査され、端末のアプリへ誤って繋がったまま進むのを防げる。
   **`finally` で必ず消す**（残ったままデバイス経路へ進むと adb が明示エラーで拒否される）:
   ```powershell
   cd uapp_e2e\driver
   $env:UAPP_E2E_EDITOR = "1"
   try {
     python -c "from e2e_driver import BridgeClient; import json; d = BridgeClient().connect().dump(); print(json.dumps(d, indent=1, ensure_ascii=False))"
   } finally { Remove-Item Env:\UAPP_E2E_EDITOR -ErrorAction SilentlyContinue }
   ```

   **デバイス（エミュレーター/実機）へ繋ぐ場合** — **`UAPP_E2E_EDITOR` は付けない**
   （付けたままだと接続先の検査に引っかかって dump できない）:
   ```powershell
   cd uapp_e2e\driver
   Remove-Item Env:\UAPP_E2E_EDITOR -ErrorAction SilentlyContinue   # 前の作業の残りを消す
   python -c "from e2e_driver import BridgeClient; import json; d = BridgeClient(port=<ホスト側ポート>).connect().dump(); print(json.dumps(d, indent=1, ensure_ascii=False))"
   ```
   大きい場合はファイルに保存してから読む
3. 要約して提示。重要情報:
   - 操作可能要素（`hittable: true` のボタン類）とそのパス
   - 遮られている要素（`hittable: false` + `blockedBy`）→ ブロッカーの解除漏れの兆候
   - テキスト（`text`）、非アクティブ要素、NGUI要素（`ui: "ngui"`）の区別
4. `NOT_FOUND` や接続エラーの場合: アプリ起動状態・forward設定・ポートを確認
   （全滅時の解析手順は `e2e-run` スキルの失敗解析を参照）
