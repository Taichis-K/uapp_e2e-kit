# AIループ開発ガイド（導入先プロジェクト用）

AIエージェント（Claude Code / Codex 等）がこの E2E 基盤を使ってアプリを自律開発するための手順書。
テスト規約の要約は `uapp_e2e/CLAUDE.md`、コマンド詳細は各スキル
（`.claude/skills/e2e-*` および `.agents/skills/e2e-*`。内容は同一）にある。

**最速の検証ループはエディタ直結**: Unity CLI＋Unity 6 以降なら `scripts/run-e2e.ps1 -Editor` が
シーン→Game view解像度→Play→pytest→Play終了まで全自動（ビルド・デバイス・adb 不要）。
実機依存の検証（logcat・adbタップ・実機描画）だけデバイス実行に回す。

エディタが閉じている状態からの実行（コールドスタート）では、**接続後にエディタが実際に応答するまで待つ**
（`unity status=ready` と「pipeline コマンドに応答できる」は別。インポート/コンパイル中は
軽いコマンドでも 30 秒のタイムアウトに達する）。待ちの上限は `-EditorReadyTimeoutSeconds`（既定600秒）で、
待機中は「待機 N 秒」が出る。

## 全体ループ

```mermaid
flowchart TD
    A["① 要件・コード読解<br/>（Grep / Read で C# を読む）"] --> B["② 内側ループ: 実装 →<br/>EditMode / PlayMode テスト（秒〜分）"]
    B -->|失敗: 修正| B
    B -->|成功| C["③ 外側ループ: 計装ビルド →<br/>エミュレーター → E2E テスト（十数分）"]
    C -->|失敗| D["④ 失敗解析<br/>pytest出力 + logcat + スクリーンショット + crash"]
    D -->|コード or テストを修正| B
    C -->|成功| E["⑤ 次の機能へ"]
    E --> A
```

**原則: ロジックは②で検証し尽くし、③は導線・入力・描画の検証に絞る。**
Android ビルドは1回十数分かかるため、③を回す頻度が高いとループが破綻する。

## 内側ループ（エディタ内テスト・ビルド不要）

```powershell
.\uapp_e2e\scripts\run-unity-tests.ps1 -Mode EditMode
.\uapp_e2e\scripts\run-unity-tests.ps1 -Mode PlayMode -Filter <テスト名の一部>
```

- **同じプロジェクトをエディタで開いたままだと実行できない**（排他ロックのため exit=6 で
  結果XMLが出ない）。エディタを閉じてから回すこと。
  **開いているかどうかは `uapp_e2e\scripts\unity-editor-status.ps1` で確認する**
  （`-Json` で機械可読）。`Get-Process Unity` では判定できない—プロセスが居ることと
  **このプロジェクトが**開いていることは別物で、他プロジェクトのエディタを自分のものと
  誤認する（逆に自分のを見落とす）。`state` は 4 値:
  `closed`＝batchmode が使える / `open`＝`-Editor` 系が使える /
  `starting-or-blocked`＝**起動途中かモーダルダイアログ待ちでどちらも失敗する**（画面を確認する）/
  `unknown`＝**プロセスを列挙できず判定できない**（理由は `warnings`。開いていない証拠が無いので
  占有されている前提で扱う＝どちらも実行しない）
- Unity CLI があればそれを、無ければ Unity 本体の `-batchmode -runTests` を自動で使う
  （エディタは `uapp_e2e/config/local.json` の editorRoots ＋ `ProjectVersion.txt` から解決）
- **Unity CLI 側だけが壊れている場合は `-NoUnityCli`** で Unity 本体の経路に直接入る
  （CLI は認証セッションが切れると `unity status` が無言で 10 分以上ハングする。`unity auth login` で復帰）。
  指定しなくても CLI が `-UnityCliProbeSeconds`（既定60秒）応答しなければ警告を出して自動で切り替わる。
  **待っている間は「待機 N 秒」が出る**ので、無言なら別の原因を疑う。
  ただし `-Editor`（エディタ内実行・エディタ直結E2E）は CLI 経由でしか成立しないため切り替えられず、
  「CLI が応答しない」と明示エラーで止まる（`unity auth login` で直すか、`-Editor` を外して回す）
- 結果は NUnit XML。**失敗テスト名・メッセージ・スタック先頭が要約表示される**ので、そこから修正対象へ直行する
- 終了ハング対策に `-TimeoutSeconds`（既定1800）で強制終了し、出力済みの結果XMLで判定する
- EditMode は既定で `-nographics`（グラフィックス初期化と USB スキャンを避ける。実行が数割速くなる）。
  描画が要る PlayMode は既定 OFF。明示指定は `-NoGraphics:$true` / `-NoGraphics:$false`（値が必須）
- ログは `Builds/test-<project>-<mode>.log` に確保される（既定の Editor.log は複数 Unity 同時実行で
  競合し、後発の実行がログを残せないことがあるため）
- **既知の制限**: Unity 2022.3 系では EditMode テストが完了しない事象を実測している（原因未特定。
  アセットインポートもライセンスも正常だが、テスト実行フェーズに入らないままタイムアウトする）。
  その場合は内側ループを諦め、E2E（外側ループ）で検証する
- テストが 0 件と警告が出たら、テストアセンブリ（`.asmdef` に `UnityEngine.TestRunner` /
  `nunit.framework.dll` 参照、`UNITY_INCLUDE_TESTS` 制約）と `-Filter` を確認する
- プロジェクトにテストアセンブリが無い場合、ロジックテストの新設はアプリ側の
  ビルド構成に影響するため、導入はユーザーに提案・確認してから行う

## 外側ループ（E2E）

```powershell
cd uapp_e2e
.\scripts\start-emulator.ps1     # 起動済みならスキップされる
.\scripts\build-android.ps1      # Assets やアプリコードを変更した時のみ
.\scripts\run-e2e.ps1            # テストのみの変更なら -SkipInstall
```

エディタ再生中のアプリに対しては adb 不要で直接接続できる
（`BridgeClient()` が `e2e-config.json` の `editorBridgePort` を自動解決。
pytest は `$env:UAPP_E2E_EDITOR = "1"; pytest tests; Remove-Item Env:\UAPP_E2E_EDITOR` で
adb を迂回して流せる。**最後の `Remove-Item` を省かない** — 立てっぱなしのまま同じシェルで
デバイス経路へ進むと、adb の使用が明示エラーで拒否され、接続先の検査にも引っかかる。
adb を直接使うテスト—logcat アサート・adb タップ—は対象外で明示エラーになるため `-k` で除外する。
ビルド不要なので外側ループの高速な代替になる。
ただし実機との差異があるため、最終確認はエミュレーター/実機で行う）。

## ジャーニー記録（画面把握・遷移・カバレッジの可視化）

画面ごとのボタン把握状況・画面遷移・テスト結果は `journey.json` に追記記録され、
自己完結 HTML レポートにできる（ユーザーへの説明・カバレッジの穴の発見に使う）。
**run-e2e.ps1 経由の実行では自動で `uapp_e2e\Builds\journey\` に記録され、テスト後に
`report.html` も更新される**（無効化は `-NoJourney`、出力先変更は `-JourneyDir`）。
pytest 直叩きの場合は `--journey <DIR>`（または環境変数 `UAPP_E2E_JOURNEY_DIR`）を付ける:

```powershell
cd uapp_e2e\driver
pytest tests --journey ..\Builds\journey
python -m e2e_driver.journey ..\Builds\journey    # → ..\Builds\journey\report.html
```

テスト側は `journey` フィクスチャを受け取り、画面の節目で capture する
（`--journey` なしの実行では no-op なので、通常の回帰実行に影響しない）:

```python
def test_open_option(g, journey):
    journey.capture("title", label="タイトル")   # dump＋スクショ＋ボタン抽出
    g = journey.wrap(g)                          # 以降の tap が操作ログ＝カバレッジになる
    g.tap("Canvas/OptionButton")
    g.wait_until_visible("OptionWindow")
    journey.capture("option", label="設定")      # 遷移 title→option が自動記録される
```

スキーマ・カバレッジ定義の詳細は `docs/07-viewer.md`。

## クリーンインストール・ブートストラップ（アプリ外の画面を含む前提づくり）

クリーンインストールで全テストを繰り返す運用では、アプリ導入直後の一度きりの導線
（利用規約・Web認証・アカウント作成・キャラ作成）を毎回自動で通す必要がある。ここは
**Unity の外**（ブラウザの認証ページ、Android の「アプリで開く」ダイアログ等）を含むため、
E2EBridge では届かない。`e2e_driver.adb` の**要素ベースのネイティブUI操作**を使う（座標非依存）:

```python
from e2e_driver import adb
adb.ui_tap(text="デバッグ用ゲスト登録", contains=True)   # uiautomatorのテキストで探してタップ
adb.ui_wait(class_name="android.widget.EditText")        # 入力欄の出現待ち
adb.current_focus()                                       # フォアグラウンドがchrome/自アプリかの判定
adb.uninstall(pkg); adb.install(apk)                      # クリーンインストール
```

要点:
- **座標で書かない**（解像度・レイアウト変化で壊れる）。`text`/`class_name`/`resource_id` で要素を指す
- Unity 画面は単一 SurfaceView で uiautomator から中身が見えない → そこは E2EBridge に切り替える
- **アプリのみのクリーンインストールでは認証Cookieが端末に残り自動ログインになることがある**。
  「新規作成が要る画面」と「自動ログインで飛ばせる画面」の両方を**出た画面だけ処理する状態機械**で書く
- アカウント名など一意制約のある入力は実行ごとにユニーク化する
- 通常スモークとは別枠にする（例: pytest マーカー＋オプトインのフラグ）。クリーンインストールは重い

## E2Eテストの書き方（規約）

`e2e-write-test` スキルの手順に従う。要点:

1. **dump を見てから書く**（推測で書かない）。ジャーニー記録（`Builds/journey/journey.json`）が
   あれば画面・ボタン・カバレッジの**索引**として先に読む。ただし過去のスナップショットなので
   使うパスは生 dump で最終確認する
2. 操作APIは `e2e-config.json` の `uiType` に従う（`ngui-legacy` は `ngui_tap` 系）
3. 待機は `wait_until_*` を使う。`time.sleep` は「待てる条件が存在しない」場合
   （物理値の安定待ち・「何も起きない」ことの確認）のみ例外とし、理由をコメントに書く
4. マルチタッチテストは logcat 例外アサートをセットにする
5. 描画検証はスクリーンショットを画像として読む

### 結果の読み方（測る前に決めておく 3 つ）

**現象を見たときに何を疑う順番か**を先に決めておく。この 3 つはキットの開発で
繰り返し時間を失った型で、導入先でも同じ形で出る:

- **赤いとき … 測り方を疑う。** 判定式の戻り値ではなく**出力そのものを見る**。
  「画面には期待どおり出ているのに判定だけ失敗」は実際に起きた（PowerShell の
  `Write-Host` が成功ストリームに乗らず、検証スクリプトの判定が空振りした）。
  ここで実装を疑いにいくと、正しい実装を長時間掘ることになる
- **緑のとき … 測った対象を疑う。** 何件・どのファイルを測ったのかを出力で確かめる。
  見つかった「偽の緑」は毎回**測っていないものを測ったつもりになっている**形だった
  （計装の登録簿が落ちた APK で全件接続エラー / 自作テスト 0 件のままの「81 passed」/
  機密語スキャンがファイルでなくパス文字列を検索して 0 件）。
  `run-e2e.ps1` のテスト内訳表示（自作 / 同梱）はこの確認を機械化したもの
- **どちらとも言えないとき … 直近の変更を証拠なしに犯人にしない。**
  疑う順番としては正しいが、**条件を 1 つずつ外して再現を取る**まで断定しない。
  実例: 削除処理を直した直後に一時ディレクトリが残り「直した処理が効いていない」と
  疑ったが、真相は**別のガードで中断した実行の残骸**だった

## 失敗解析の優先順位

1. pytest の失敗メッセージ（`BlockedError` は遮蔽者のパスを含む）
2. `uapp_e2e/Builds/failure/unity-logcat.txt` の例外スタック → 修正対象コードの特定に直結
3. `uapp_e2e/Builds/failure/screen.png` を画像として読む
4. **全テスト接続エラーなら `uapp_e2e/Builds/failure/crash.txt`**（ネイティブクラッシュはUnityタグに出ない）。
   `adb shell pidof <package>` が空ならプロセス死亡。アプリが生きていて接続だけ死んでいるなら
   エミュレーター疲弊を疑い `adb reboot`（リブート直後の起動は1〜2分置く）
5. dump を再取得して期待した UI 状態との差分を見る
6. **エディタ直結で Unity CLI の呼び出しが失敗した**なら
   `uapp_e2e/Builds/failure/unity-cli-raw.txt`（run-e2e が自動保存する生の応答）を見る。
   **JSON にできなかった応答**と、**分類できなかった CLI エラー**（`[未知のエラー文]` タグ付き）の
   2 種類が残る。後者は「待てば直るはずのエラーを取りこぼした」可能性があるので、
   **出た文言を報告する**（分類に足せば直る。issue #38 の実例）。
   ファイルは実行の先頭で切り詰められ、以後は追記される。
7. **出力を丸ごとファイルへ残すときは `Start-Transcript` か `6>&1`**。
   キットの進捗行は `Write-Host`（情報ストリーム）なので **`2>&1 | Tee-Object` では取れない**
   （pytest の標準出力だけが残る）。導入先で実際に踏まれた
   なお**自作の .ps1 から `unity cmd` を直接叩く場合は、スクリプト先頭で
   `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)` を宣言する**
   （コンソールを持たない起動では OEM に落ち、日本語を含む応答だけ JSON が壊れる）

判断基準: 失敗が「実ユーザーにも起きる」ならアプリを直す。「テストの前提が誤り」ならテストを直す。

## （任意）エージェント開発ダッシュボード連携

複数プロジェクト・複数タスクを並行で回すときのために、テスト・E2E・ビルドの結果を
**1 行だけ外部へ記録する**エミッタ（`uapp_e2e/scripts/emit-status.ps1`）を同梱している。

- **プロジェクト直下に `.agent-status/` があるとき（または環境変数 `UAPP_E2E_STATUS_DIR` が実在する
  ディレクトリを指すとき）だけ書く**。探索は `uapp_e2e` とその親の 2 階層まで。無ければ完全に
  何もしない＝**導入していない環境では挙動が一切変わらない**（ファイルも pytest の引数も増えない）
- 追加の依存は無い（PowerShell が NDJSON を追記するだけ。ダッシュボード本体は別リポジトリの任意ツール）
- 記録先: `run-unity-tests.ps1` → テスト結果 / `run-e2e.ps1` → E2E 件数と journey レポートのパス /
  `build-android.ps1` → ビルド結果。作業単位を分けたいときは `UAPP_E2E_UNIT_ID` を渡す
- 失敗は握りつぶすので、**連携が壊れてもテスト・ビルドの結果には影響しない**

## 開発時の注意

- `Assets/uapp_e2e/E2EBridge/` を変更したら `docs/02-protocol.md` と `driver/e2e_driver/` を必ず同期
- 計装は define があるビルドのみ有効。**本番ビルドに define を付けない**
- アプリへのテスト用フック（画面直行のディープリンク等）追加は有効な手段だが、
  本番コードに影響するためユーザーに提案・確認してから行う
- **導入先の既存ビルドスクリプトがCWD依存**（相対パスで兄弟バッチを呼ぶ・カレントディレクトリ前提の
  パス解決をする等）**の場合、AIハーネスやCIからの実行では壊れることがある**。
  真因の代表は **環境変数 `NoDefaultCurrentDirectoryInExePath=1`**（AIハーネス等のセキュリティ設定。
  cmd がカレントディレクトリの実行ファイルを探さなくなり、bat 内の `call 兄弟バッチ名` が
  「〜が認識されていません」で失敗する）。対処は、実行前にこの環境変数を一時的に外す
  （PowerShell: `Remove-Item Env:\NoDefaultCurrentDirectoryInExePath`）か、
  該当ステップを**絶対パス（.\ 付き）で再現する薄いスクリプト**に置き換える

## 計測と受け入れ判定の作法（issue #49）

通しを「機能確認」だけでなく**測定**にも使うときの規約。導入先が長時間の自動プレイで
固めた作法の一般解で、**4 点とも実際に踏んだ失敗から来ている**。

### 1. 成功判定に「回復しうる値の減少」を使わない

導入先は「ある残数が減ったこと」で操作の成功を判定していたが、その値は**時間で回復**し、
**消費しない実行モード**もあったため、**実際には成立しているのに失敗と判定**した。

**判定は「状態が前に進んだ証拠」に置く** ― 新しいウィンドウが出た・画面が変わった・
アプリ側の記録が増えた。**減った/増えたは、戻りうるなら証拠にならない。**

### 2. 表示値の読み取りは `get` を使う

`dump` の `text` をパースするより、`get` でプロパティを直接読むほうが堅い。
`1.08K` のような省略表記や `24 / 50` のような複合表記に引っかからない
（`docs/02-protocol.md` の `get` を参照）。

### 3. 測るなら `metrics` を使い、**先頭に目的と設定を書く**

`--metrics <DIR>`（または `UAPP_E2E_METRICS_DIR`）で有効になる。**既定は書かない。**

```python
def test_stage1(client, metrics):
    metrics.begin("ステージ1の所要時間", build="Release", debugAssist=False)
    ...
    metrics.record("stage1_seconds", 42.5)
```

**`begin` を省かない。** これが無いと「**この記録は比較してよい記録か**」が後から判断できない
（デバッグ機能で状態を注入した回はバランスの参考にならない、など）。
出力は `<DIR>/<runId>.jsonl`（1 行 1 イベント・先頭が run のヘッダ）と `<DIR>/summary.csv`。

**`summary.csv` は BOM 付き UTF-8 で書かれる。** これは**人が Excel で開く前提**のファイルで、
**BOM の無い UTF-8 の CSV を Excel は cp932 として読む**ため、無いと列名が化ける。
自分でこのファイルを読むときは **`utf-8-sig` で開く**こと ―
素の `utf-8` でも**例外は出ないが、最初の列名が `runId` ではなくなる**（列が増えたように見える）。
既存の `summary.csv` が cp932（Excel で保存された）でも読めるようになっている。

### 4. アプリ自身の記録を受け入れ条件にする

導入先がアプリ側の通過記録を読んで判定するようにしたところ、
**ログでは失敗に見えた操作が実際は成立していた**ことが分かった。
逆に「未記録」を見つけたら、**まず記録側の条件を疑う**（特定の局面でしか記録されない、など）。

一般化すると「**アプリが持つ真実の記録を読む口を 1 つ用意し、それを受け入れ条件にする**」。
**操作の応答が 200 でも、それは操作が効いた証拠にはならない**
（OS エージェントの `/tap` `/swipe` は無条件に `ok:true` を返す）。
**「接続できた」も同じ** ― iOS 実機では `iproxy` がアプリ未起動でもホスト側ポートを LISTEN し、
**`connect()` も `send()` も成功して `recv()` で初めて切れる**（2026-08-26 に実測）。
**握手が通ったことは、相手が生きている証拠にならない。**
