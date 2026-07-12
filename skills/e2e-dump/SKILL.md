---
name: e2e-dump
description: 実行中のUnityアプリのUI階層をdumpして見やすく要約する。「今の画面のUI構造を見せて」「dumpして」「この画面に何があるか調べて」等で使用。
---

# UI階層のdumpと要約

実行中のアプリ（エミュレーター or エディタ再生）から UI 階層を取得して要約する。

## 手順

1. 接続先を判断:
   - エミュレーター: `adb forward` 済みのホストポート（`uapp_e2e/config/local.json` の `bridgePort`）
   - エディタ再生中: `uapp_e2e/e2e-config.json` の `editorBridgePort`
2. 取得:
   ```powershell
   cd uapp_e2e\driver
   python -c "from e2e_driver import BridgeClient; import json; d = BridgeClient(port=<ポート>).connect().dump(); print(json.dumps(d, indent=1, ensure_ascii=False))"
   ```
   大きい場合はファイルに保存してから読む
3. 要約して提示。重要情報:
   - 操作可能要素（`hittable: true` のボタン類）とそのパス
   - 遮られている要素（`hittable: false` + `blockedBy`）→ ブロッカーの解除漏れの兆候
   - テキスト（`text`）、非アクティブ要素、NGUI要素（`ui: "ngui"`）の区別
4. `NOT_FOUND` や接続エラーの場合: アプリ起動状態・forward設定・ポートを確認
   （全滅時の解析手順は `/e2e-run` スキルの失敗解析を参照）
