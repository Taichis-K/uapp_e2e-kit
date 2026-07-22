# 07. ジャーニービューアー（画面把握・テスト結果・カバレッジの可視化）

E2E テスト中に「各画面のボタンをどう把握できているか」「どのボタン・画面遷移がテスト済みか」を
記録し、**自己完結 HTML**（外部依存なし・ブラウザで開くだけ）で閲覧する仕組み。

- 記録: `e2e_driver.journey.JourneyRecorder`（dump＋スクリーンショット＋操作ログを情報ファイルに追記）
- 情報ファイル: `journey.json`（下記スキーマ）＋ `screens/*.png`
- 閲覧: `python -m e2e_driver.journey <journey_dir>` → `report.html` 生成（スクショを data URI で内蔵した単一ファイル）

## 使い方

### run-e2e.ps1 から記録する（推奨・自動）

`run-e2e.ps1` は既定でジャーニー記録を有効化し、テスト後に report.html を自動更新する。
出力先は**常に同じ場所**: 導入先（キット配置）は `uapp_e2e\Builds\journey\`、
開発リポジトリは `Builds\journey\<サンプル名>\`。

```powershell
.\scripts\run-e2e.ps1                       # → Builds\journey\<サンプル名>\report.html が更新される（導入先は uapp_e2e\Builds\journey\）
.\scripts\run-e2e.ps1 -NoJourney            # 記録を無効化
.\scripts\run-e2e.ps1 -JourneyDir <DIR>     # 出力先を変える（別ジャーニーを分けたい時）
```

### pytest から記録する（部分実行・手動）

```powershell
cd driver
pytest tests -k smoke --journey ..\Builds\journey   # または環境変数 UAPP_E2E_JOURNEY_DIR
python -m e2e_driver.journey ..\Builds\journey      # → ..\Builds\journey\report.html
```

テスト側は `journey` フィクスチャを受け取り、画面の節目で `capture` する。
タップの記録は `journey.wrap(g)` が返すプロキシ経由で自動化される:

```python
def test_open_option(g, journey):
    journey.capture("title", label="タイトル")      # dump+スクショ+ボタン抽出を記録
    g = journey.wrap(g)                             # 以降の tap/ngui_tap が操作ログに残る
    g.ngui_tap("UI Root/BtnOption")
    g.wait_until_visible("OptionWindow")
    journey.capture("option", label="設定ダイアログ") # 直前のtapから遷移 title→option を自動記録
```

- テストの pass/fail は pytest フックが自動で記録する（`journey` フィクスチャを使ったテストが対象）
- 記録は**追記マージ**: 既存 `journey.json` があれば画面は id で上書き、テストは名前で上書き。
  複数回の実行・複数テストファイルの結果が 1 つのジャーニーに蓄積される

### pytest なしで探索記録する

```python
from e2e_driver import BridgeClient, Gestures
from e2e_driver.journey import JourneyRecorder

c = BridgeClient().connect()
j = JourneyRecorder(c, "Builds/journey")
j.capture("title")           # 現在画面を記録（スクショは adb 必須。エディタ直結時は自動スキップ）
g = j.wrap(Gestures(c))
g.tap("Canvas/StartButton")
j.capture("home")            # 遷移 title -[Canvas/StartButton]-> home が自動記録される
j.save()
```

## 情報ファイル（journey.json）スキーマ `uapp-e2e-journey/1`

```jsonc
{
  "format": "uapp-e2e-journey/1",
  "app": {                        // ping の結果から採取
    "package": "com.uapp.e2esample",
    "unity": "6000.3.6f1",
    "bridge": "1.0",
    "screen": {"w": 2400, "h": 1080}
  },
  "updatedAt": "2026-07-12T12:34:56+09:00",

  "screens": [                    // 画面 = capture() 単位。id で一意（再captureは上書き）
    {
      "id": "title",              // capture() 呼び出し側が付ける安定ID
      "label": "タイトル",         // 表示名（省略時 id）
      "scene": "TitleScene",      // dump の scene
      "screen": {"w": 2400, "h": 1080},   // capture時の Unity 解像度（座標系の基準）
      "screenshot": "screens/title.png",  // journey.json からの相対パス。取得不可なら null
      "capturedAt": "2026-07-12T12:34:56+09:00",
      "buttons": [                // dump(probe=selectable) で hittable 判定が付いたノード
        {
          "path": "UI Root/Camera/BtnStart",
          "name": "BtnStart",
          "text": "スタート",      // UILabel/Text/TMP から拾えた場合のみ
          "ui": "ngui",           // NGUI要素のみ。uGUIは省略
          "rect": {"x": 240, "y": 180, "w": 300, "h": 100},   // Unityスクリーン座標（左下原点）
          "center": {"x": 390, "y": 230},
          "interactable": true,   // dump が返した場合のみ
          "hittable": true,
          "blockedBy": null       // 遮蔽時のみ遮蔽オブジェクトのパス
        }
      ]
    }
  ],

  "transitions": [                // 画面遷移。capture() 間のタップから自動記録
    {
      "from": "title",
      "to": "option",
      "via": "UI Root/BtnOption", // 遷移を起こしたタップのパス。タップ以外の遷移は null
      "test": "tests/test_x.py::test_open_option"   // 記録したテスト。手動記録は null
    }
  ],

  "tests": [                      // journey フィクスチャを使ったテストの結果
    {
      "name": "tests/test_x.py::test_open_option",
      "outcome": "passed",        // 最新の結果: passed | failed | error | skipped
      "duration": 3.2,            // 秒
      "ranAt": "2026-07-12T12:34:56+09:00",
      "regressed": false,         // 前回 passed → 今回 failed/error なら true（回帰検知）
      "history": [                // 実行履歴の累積（古い順・最大20件）
        {"outcome": "passed", "ranAt": "2026-07-11T18:00:00+09:00", "duration": 3.0}
      ],
      "actions": [                // wrap(g) 経由の操作ログ。**実行をまたいで累積マージ**
        {"kind": "tap", "screen": "title", "path": "UI Root/BtnOption"}
        // kind: tap | ngui_tap | press | ngui_press | pinch
      ]
    }
  ]
}
```

**回帰（regressed）は AI の修正トリガー**: journey.json で `"regressed": true` を見つけたら、
直近の自分の変更（アプリコード・テスト・計装）が影響した可能性を最優先で調査する。
一時的要因（サーバー状態・タイミング）の可能性もあるため、まず再実行で再現性を確認してから切り分ける。

### カバレッジの定義（ビューアーが算出。ファイルには持たない）

- **ボタンカバレッジ** = 画面ごとに `actions` でタップされた `path` の集合 / その画面の `buttons` のうち
  `hittable: true` のもの。失敗テストのみの操作は「試行あり（未確認）」として区別表示
- **遷移カバレッジ** = `transitions` のうち passed テスト由来のもの
- 座標系: ボタンの rect は Unity スクリーン座標（左下原点）。ビューアーはスクショ画像の実サイズと
  `screen.w/h` の比でスケールし、Y 軸を反転してオーバーレイする

## ビューアー

- テンプレート: `driver/e2e_driver/viewer.html`（キットにも同梱される）
- `python -m e2e_driver.journey <dir>` が journey.json とスクショを**インライン**した
  `report.html` を生成。単一ファイルなのでそのまま共有可能
- 生成せずに `viewer.html` を直接ブラウザで開くこともできる。データの解決順:
  1. `viewer.html?data=<journey.jsへの相対パス>`（URL指定。スクショもそのディレクトリ基準で解決）
  2. パラメータ無しなら同ディレクトリの `journey.js` を自動読込
     （レコーダーが journey.json と併せて出力する。journey ディレクトリに viewer.html を置くだけで開ける）
  3. どちらも無ければファイル選択ダイアログ（この場合スクショは同ディレクトリ配置時のみ表示）
  ※ `.js` 形式を使うのは file:// では fetch が CORS 制限で使えないため（`<script src>` は可）
- 表示内容: 画面一覧（スクショ＋ボタンオーバーレイ。テスト済み/未テスト/遮蔽を色分け）、
  画面遷移グラフ、テスト結果一覧、カバレッジサマリー

## 探索モード（ビューアーからの実機タップ）

```powershell
cd uapp_e2e\driver
python -m e2e_driver.journey serve ..\Builds\journey   # → http://127.0.0.1:8787/viewer.html
```

アプリ実行中（adb forward 済み）にビューアーを **serve 経由**で開くと、遮蔽中以外のボタンに
「▶ タップ」が表示される。クリックすると:

1. サーバーが**実機の現在画面を照合**（ボタン構成の類似度）。表示中のビューアーの画面と
   ズレていたら**タップせず**、実機の現状を取り込んで表示を合わせる（誤操作防止）
2. 一致していればタップ（`uiType` は e2e-config.json から自動判定。`ngui-legacy` なら `ngui_tap`）
3. タップ後の画面を既知画面と照合。既知なら遷移として記録、未知なら新画面
   `probe-<ボタン名>` として自動キャプチャ
4. `viewer-probe::<ボタン名>` テストとして結果を記録し、ビューアーが即時更新される

ヘッダーの「⟳ 実機の画面を取り込む」で、いつでも実機の現状に表示を同期できる
（既知画面ならスクショ更新、未知なら `screen-N（自動取得）` として追加）。

未テストのボタンを順に押していくだけで、画面地図とカバレッジが育つ。
待ち受けは 127.0.0.1 のみ。ブリッジ接続先は `--bridge-port`
（既定: 環境変数 UAPP_E2E_BRIDGE_PORT → journey ディレクトリ起点で探索した e2e-config.json の
editorBridgePort → 13333。**adb forward 済みデバイスを探索する場合はホスト側ポートを明示する**）。

## ボタンデータの再利用（テスト作成の「地図」としての運用）

journey.json は可視化専用ではなく、**AI がテストを書くときの索引（地図）として再利用する**:

- テスト新規作成の最初に journey.json を読み、「どの画面に何のボタンがあるか」
  「どこが未テストか」「どのボタンでどの画面へ遷移するか」を把握してから対象を決める
- カバレッジの穴（未テストのボタン・遷移先のテスト状況バッジが 0 の画面）が次に書くテストの候補
- **記録は過去のスナップショット**。テストに使うパスは必ず生 dump（`/e2e-dump`）で最終確認する
  （この規約は kit の CLAUDE.md / e2e-write-test スキルにも記載）

## 制約

- スクリーンショットは adb 経由（デバイス/AVD のみ）。エディタ直結時は screenshot なしで記録される
- 「ボタン」の判定は dump の probe=selectable と同じ（uGUI Selectable ＋ NGUI コライダー保持ノード）。
  独自入力実装のボタンは写らないことがある — その場合 dump を確認し `probe="all"` で capture する
- 記録した瞬間のスナップショットであり、ライブ表示ではない
