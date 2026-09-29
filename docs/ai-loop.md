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
  `starting-or-blocked`＝**起動途中かモーダルダイアログ待ちでどちらも失敗する**（画面を確認する。
  mac で画面を機械で見るなら「OS レベルの UI オートメーション › やること: mac 自身を見る側」）/
  `unknown`＝**プロセスを列挙できず判定できない**（理由は `warnings`。開いていない証拠が無いので
  占有されている前提で扱う＝どちらも実行しない）
- **`-Editor` 系でエディタが応答しないとき（macOS）の候補**: ①Mac の画面ロック中 ― エディタが進まず pipeline のコマンドがタイムアウトする。ロックを解除すれば戻る ②WindowServer との接続が切れた ― `Editor.log` に `WindowServer event port death` が出る。モーダルが閉じないので、エディタを終了して開き直す。エディタを起動し直す前に `Editor.log`（`~/Library/Logs/Unity/`）を退避する（直前の 1 世代は `Editor-prev.log` に残るが、次の起動で上書きされる）
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
.\scripts\build-android.ps1      # Assets やアプリコードを変更した時のみ。エミュレーターは止めた状態で
                                 #（動いていると始まらない。奪い合いが無い環境なら -AllowRunningEmulator）
.\scripts\start-emulator.ps1     # 起動済みならスキップされる ― ビルドが終わってから
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
2. 操作APIは `e2e-config.json` の `uiType` に従う（`ngui-legacy` は `ngui_tap` 系 / `ugui-legacy` は `ugui_tap` 系）
3. 待機は `wait_until_*` を使う。`time.sleep` は「待てる条件が存在しない」場合
   （物理値の安定待ち・「何も起きない」ことの確認）のみ例外とし、理由をコメントに書く
4. マルチタッチテストは logcat 例外アサートをセットにする
5. 描画検証はスクリーンショットを画像として読む
6. **アプリの外は計装では触れない**（issue #66）。**外部ブラウザ・システムダイアログ・
   ソフトウェアキーボード・他アプリ・IMGUI（`OnGUI`）は `dump` にも出ず `tap` でも押せない** ―
   計装は Unity アプリの中で動いているため。
   使うのは **Android: `adb.ui_tap` / `adb.ui_type`、iOS: `os_agent.tap` / `os_agent.type_text` /
   `os_agent.handle_alert`**（`from e2e_driver import adb, os_agent`。
   iOS は `run-ios-e2e.ps1 -OsAgent` で起動しておく）。
   **文字入力が要る導線は、ここを知らないと詰まる** ― 実際に導入先が
   「入力欄に値を入れられずテストが進まない」で止まった

### アプリ独自の入力層へ届かせる（`Input.GetKey` / 自作のキーコントローラ）

**当てはまる構成**: `pad_*` / `key_*` / `pointer_*` がすべて `INPUT_SYSTEM_NOT_PRESENT`（または
`INPUT_BACKEND_LEGACY`）で、動くのは `ugui_event` だけ。ゲームパッド操作が要件のアプリで出る。
**アプリが `Input.GetKey` / `Input.GetAxis` を直に読んでいるなら、`com.unity.inputsystem` を入れても届かない**
（注入 API はレガシーのバックエンドを触らない）。

**やること**

1. **Android なら先に OS の実入力を試す。** `adb shell input keyevent <KEYCODE>` はレガシー Input にも届く。
   アプリを変えずに実機の入力経路そのものを通せる。このキットでは未実測なので、採用するなら最初に 1 回、
   アプリの入力層まで届くかを確かめる。
2. **それ以外（エディタ直結・コンソール機など）は、アプリ側に注入口を作り、隠した uGUI 要素を `ugui_event` で叩く。**
   - 入力層に `#if UAPP_E2E_BRIDGE` で注入口を足す（外から押下集合・方向を与え、既存の判定に OR する）。
     **注入口・MonoBehaviour の全部を `#if UAPP_E2E_BRIDGE` で囲み、隠し要素（GameObject）は `#if` の中のコードで
     実行時に生成する**（本番ビルドに残さない）。**シーンや Prefab に置かない** ― `#if` で消えるのは C# だけで、
     置いた GameObject は本番ビルドにも残り、型が消えたぶんが Missing Script になる
   - `IPointerDownHandler` / `IPointerUpHandler` を実装した MonoBehaviour を、生成した GameObject に**ボタン・方向ごとに 1 つずつ**付ける
     （`path` がボタンを表し、`press` / `release` が down / up に対応する）。**`IPointerDownHandler` は必須**
     （`release` の送出先は押したときの受け手で決まる）
   - `client.ugui_event(path, "press")` を直接呼ぶ（`Gestures.ugui_tap` / `ugui_press` は `hittable` で弾くので使えない）
   - **応答の `handler` が自分の `path` であることを assert する。** `null` なら誰も受け取っていない。
     `hittable` / `blockedBy` は不可視化でも落ちるので判定に使えない
   - GameObject は active・コンポーネントは enabled のまま、alpha 0 / サイズ 0 / 画面外で不可視にする
3. **置き場所と名前。** `Assets/uapp_e2e/E2EBridge/` の下に置かない（アンインストールで丸ごと消える）。
   `dump` に出るので用途が分かる名前にする（例 `E2EPad/ButtonA`）。
   **キット本体（`CommandProcessor.cs` など）は編集しない**（更新で上書き・改変検知・アンインストールで削除）。
4. **実入力での疎通を、少なくとも 1 本は別に通す。** この技法が検証するのは注入口から先で、
   実デバイスの入力経路ではない。注入口が本来のゲート（入力ロック・フォーカス）を迂回していると、
   テストは緑なのに実機のパッドでは動かない。

**補足**

- 見えない要素でも叩けるのは仕様。`ugui_event` は raycast が外れても `path` の対象自身へ送る
  （`docs/02-protocol.md`: 到達可能性は検証しないが送出そのものは行われる）
- 「非アクティブだと届かない」は `ExecuteEvents` の仕様からの推論で、このキットでは未実測。だから `handler` を見る
- ブリッジの注入は 2 通り: Input System 経由（`pointer_*`・`key_*`・`mouse_*`・`pad_*`）と
  UI フレームワークへ直送（`ugui_event` / `ngui_event`）。前者だけがパッケージと入力バックエンドに依存する
  （エラーコードは `docs/02-protocol.md`）

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
   エミュレーター疲弊を疑い `adb reboot`（リブート直後の起動は1〜2分置く）。
   **`crash.txt` が空で `[E2EBridge] listening` も出ているのに繋がらないなら、
   下の「よくある詰まり」の「端末の画面がオフ、またはロックされている」を見る**
   （コードではなく端末の状態が原因のことがある）
4.5 **iOS で「ブリッジが応答しない」なら、まず OS のシステムアラートを疑う**。
   **権限ダイアログ等が出ている間、iOS はアプリを非アクティブにする**ので Unity の
   メインスレッドが進まず、ping がタイムアウトする。**アプリは壊れていない** ―
   **押したいボタン名を指定して**閉じると（`os_agent.handle_alert("許可しない")`）**即座に復帰する**。
   **省略すると先頭のボタンが押される**ので、確認のつもりで引数なしを使わないこと。
   **ドライバのタイムアウトは「アプリがフリーズ/ANR」も候補に挙げるが、この経路ではそれが誤り**。
   アラートが出うる導線（位置情報・通知・ATT・ローカルネットワーク）では、
   **異常と読む前にシステムアラートを疑う**（2026-09-10 に導入先が実機で実測）
5. dump を再取得して期待した UI 状態との差分を見る
5.5 **`dump` / `texts` の応答に `readErrors` があれば、そこは読めていない**（issue #64）。
   **実機（IL2CPP ＋ Managed Stripping）でだけ起きる** ― **誰も呼ばない getter が削られる**ので、
   その型の `text` が `null` になる。**エディタでは再現しない**（stripping が掛からない）ため、
   内側ループが緑のまま実機だけで欠ける。

   ```json
   "readErrors": [
     { "type": "UnityEngine.TextMesh", "assembly": "UnityEngine.TextRenderingModule",
       "property": "text", "path": "...", "count": 4, "error": "Get Method not found for 'text'" }
   ]
   ```

   **値も読みたいなら、その 2 つをそのまま `link.xml` へ写す**（`Assets/` の下に置く）:

   ```xml
   <linker>
     <assembly fullname="readErrors の assembly">
       <type fullname="readErrors の type" preserve="methods"/>
     </assembly>
   </linker>
   ```

   **保持すべき型はプロジェクトによる**（3D テキスト・NGUI・独自の派生・第三者 DLL）ので、
   キットは雛形に型を並べない。**`readErrors` が教える**。
   直らないときは **Managed Stripping Level を一時的に Disabled にしてビルド**して切り分ける
   （それで直れば stripping が原因と確定し、`link.xml` の書き方の問題に絞れる）
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

## よくある詰まり（導入先で実際に出たもの）

上の優先順位で証跡を見ても原因が絞れないときの候補。
セットアップ時の詰まり（没入モード確認オーバーレイなど）は `docs/05-install-to-project.md` 側。

### 全テストが接続エラー — 端末の画面がオフ、またはロックされている

**症状**: ブリッジへ繋がらず全件エラー。アプリもビルドも直前まで正常。しばらく放置したあとに回すと再現しやすい。

**やること**

1. `adb shell dumpsys window` の `mCurrentFocus` を見る。ロック画面やシステム UI がフォーカスを持っていればそれが原因
   （人が居るなら端末の画面を直接見るのが最短）
2. 画面を点けてロックを解除してから回す
3. 無人実行では端末側でスリープを切っておく:
   `adb shell settings put system screen_off_timeout 2147483647` / `adb shell svc power stayon true`（このキットでは未実測）

**補足**: `crash.txt` が空で `[E2EBridge] listening` も出ているのに繋がらないときは、コードではなく端末の状態を先に疑う。
`mCurrentFocus` はキット自身が使っている信号（`docs/05` の没入モードの節・`run-e2e.ps1` の失敗メッセージ）。

### 起動直後に `texts` / `dump` が 0 件で落ちる

**症状**: 同梱スモークの `test_texts_collects_only_the_requested_types` などが、アプリ起動直後の走行でだけ 0 件になる。
少し待ってから回すと通る。

**やること**

1. 収集の前に `wait_until_*` で最初の画面の目印が出るまで待つ
2. 最初の画面に該当する要素がそもそも無いアプリなら、**理由を書いて**そのテストを外す（`-k` か marker）

**補足**: ブリッジは先に立ち上がるが、スプラッシュやタイトル前の暗転中は UI が構築されておらず、要素が本当に 0 件になる。
同梱スモークには「サンプルには必ずある」という前提が入っているものがある。自分のアプリで落ちたら、まず前提が構成に当てはまるかを見る。

## OS レベルの UI オートメーション（iOS の OS エージェント / mac 自身を見る側）

### 用語（3 つある。混ぜない）

| 呼び方 | 何をするもの | 対象 | トークン |
|---|---|---|---|
| OS エージェント | XCUITest 経由の `/tap` `/swipe` `/alert` `/screenshot` | iOS 実機・シミュレータ | 要る（`X-Uapp-Token`） |
| mac 自身を見る側 | `System Events` / `CGWindowList` / `screencapture` | mac のアプリ（Unity エディタのモーダル判定など） | 無い。要るのは OS の権限 |
| 端末設定の「UI オートメーションを有効」 | iOS の設定 → デベロッパ | iOS 実機 | — （OS エージェントの前提） |

権限と端末設定は `SETUP.md`（端末設定は「iOS で使う場合」、mac の権限は「macOS で使う場合」）。

### やること: OS エージェント

1. **`/status` は 200 だけで判断せず、`authenticated:true` まで見る。**
   `false` なら認証が効いていない（トークンを空で起動している。ソース上はこれ以外の原因が無い。
   この象限そのものは未実測）。張り直す。
2. **トークンを保存しない。** 必要になったら下の回収を使う。
   どうしても保存するなら `uapp_e2e/Builds/` 配下に 0600 で書き、終了時に消す。
   **その前に `.gitignore` に入っていることを自分で確かめる**（installer は表示するだけ）。
3. **トークンが分からなくなったら、エージェントのプロセスから回収する。**
   `TOKEN=$(openssl rand -hex 16)` は**次のツール呼び出しには残らない**（別プロセスの別シェルになる）。
   **経路で分かれる**: シミュレータ → 下の 1 本目 / 実機で `docs/09` の go-ios 手組み → 下の 2 本目 /
   **実機で `-OsAgent -Target device`（CoreDevice が `paired` な端末）→ 回収せず起動し直す**
   （ホスト側で env を持つのは `xcodebuild` だけで、そこは `ps` から読めない。go-ios 用を流しても 0 件で止まる）。

   シミュレータ:

   ```bash
   PIDS=""
   [ -n "${UDID:-}" ] && PIDS=$(pgrep -f 'UappOsAgentRunner-Runner' | while read -r pid; do
       [ "$(ps -ww -o comm= -p "$pid" | sed 's|.*/||')" = UappOsAgentRunner-Runner ] || continue
       ps -ww -o args= -p "$pid" | grep -qi "Devices/$UDID/" && echo "$pid"
     done)
   N=$(printf '%s' "$PIDS" | grep -c . || true)
   TOK=""
   [ "$N" = 1 ] && TOK=$(ps -Eww -p "$PIDS" | tr ' ' '\n' \
                         | grep -m1 '^UAPP_OS_AGENT_TOKEN=' | cut -d= -f2)
   [ ${#TOK} -eq 32 ] || { echo "回収できなかった（UDID='${UDID:-(空)}' / ランナー $N 件 / 32 文字でない）"; false; }
   ```

   実機（`docs/09-ios16-osagent.md` の go-ios 手組み。トークンは argv に載る）:

   ```bash
   PIDS=""
   [ -n "${UDID:-}" ] && PIDS=$(pgrep -f 'goios/ios runtest' | while read -r pid; do
       [ "$(ps -ww -o comm= -p "$pid" | sed 's|.*/||')" = ios ] || continue
       ps -ww -o args= -p "$pid" | grep -qi "$UDID" && echo "$pid"
     done)
   N=$(printf '%s' "$PIDS" | grep -c . || true)
   REC=""
   [ "$N" = 1 ] && REC=$(ps -ww -o args= -p "$PIDS" | tr ' ' '\n' \
                         | grep -m1 '^--env=UAPP_OS_AGENT_TOKEN=' | cut -d= -f3)
   [ ${#REC} -eq 32 ] || { echo "回収できなかった（UDID='${UDID:-(空)}' / 該当 $N 件 / 32 文字でない）"; false; }
   ```

4. **401 が出たら、この順で潰す。** 401 は**原因が違っても文言が同じ**なので、そこからは切り分けられない。
   1. ヘッダが空でないか（`$TOKEN` が空のまま送っていないか）
   2. 上の回収で取ったトークンで通るか
   3. そのポートを握っているのは誰か（`lsof -nP -iTCP:<port> -sTCP:LISTEN`）。
      シミュレータならランナー自身が出る。**実機は `iproxy` が出るだけで、その先がどの個体かは分からない**
      （生きていても死んでいても同じに見える）。実機で取り違えを疑うなら `iproxy` を落として張り直す
   4. それでも駄目なら起動し直す
5. **孤児（前の走行が残したエージェント）は 401 から探さない。** プロセスとポートで見る。

   ```bash
   pgrep -f 'UappOsAgentRunner-Runner' | while read -r pid; do
     [ "$(ps -ww -o comm= -p "$pid" | sed 's|.*/||')" = UappOsAgentRunner-Runner ] && echo "$pid"
   done
   lsof -nP -iTCP:<port> -sTCP:LISTEN
   ```

### やること: mac 自身を見る側

1. **`0` や空文字を「無い」と読まない。** mac のウィンドウ調査は**エラーではなく「無い」と答えて外れる**。
   - `System Events` の `count of windows` は `0` を返す（プロセス列挙は通るのに。**Unity エディタのプロセスに対して**、
     アクセシビリティの許可が通っていても、正常・メインスレッド占有・モーダルの 3 状態とも 0。mac の実測。他のアプリでは未確認）
   - `CGWindowList` は Unity のウィンドウ名を**空**で返す（他アプリの名前は取れる）＝名前で判定できない
   - AppleScript の `keystroke` ではモーダルを閉じられない
2. **「無い」と答えうる問いを避け、存在すれば必ず何か返る問いに置き換える。**
   `/alert` に存在しないボタン名を渡して `available` を得る手（`docs/09-ios16-osagent.md`）がその形。
3. **エディタがモーダルで止まっているかを見るなら、画像で見る。**
   `CGWindowList` で対象 PID のウィンドウを列挙（名前は空でも id と大きさは取れる）→
   `screencapture -x -o -l <windowId> "$SHOT"`（保存先のパスを与える。`SHOT=$(mktemp -t uapp-win)`）→
   **次のツール呼び出しで `$SHOT` を画像として読む** → 読んだあとに消す。
   **枚数や大きさを判定条件にしない。**
   （`sample <pid>` のスタックでモーダルを判定する手は、このキットに一次記録が無いので載せていない）
4. **許可が要る操作は人に頼む。** 許可ダイアログは AI から見えず押せない。

---

### 補足

**回収スニペットの設計**

- **`comm` で実体を確かめている。** argv の一致だけで拾うと、その文字列を引数に持つだけのプロセスが混ざる。
  **最も踏みやすいのは貼り付けたシェル自身**（`UDID=<値> bash -c '<スニペット>'` はスニペット本文と UDID を
  自分の argv に載せる）。塞がない形は、**エージェントが居ないのに 32 文字を「回収」して成功扱いになった**。
  実体名は `UappOsAgentRunner-Runner` / `ios`（**Xcode や go-ios の版で変わりうる**）
- **`false` は打ち切らない**ので、門は `&&` 側に置いている（`PIDS=""` を先に置く）。
  最終行以外を `|| { …; false; }` にすると次の行が走り、go-ios 側は `grep -qi ""` が全行に一致して嘘の件数に届く
  （最終行の `false` は「この後ろに繋ぐなら非 0 を見よ」の印で、打ち切りではない）
- `ps` に `-ww` を付けてある。BSD の `ps` は出力先が tty のとき端末幅で最終カラムを切る、という指摘があったため。
  **コマンド置換・パイプ経由では切られないことを実測した**（404 文字の argv がそのまま取れた）ので、
  この使い方では無くても動く。無害なので付けてある
- **件数の門は 0 件と 2 件以上の両方を塞ぐ**（`head -1` だと 2 個体のとき黙って片方を選ぶ）
- **メッセージは 1 本にし、件数と UDID を添えて原因を名指ししない**（0 件のときは env を読んでいない）
- 長さ 32 は**文字種を見ない**。go-ios 側は `docs/09` どおり `./goios/ios` で起動する前提
  （bundle id を上書きしてもプロセス名は変わらないので、ここは書き換えない）
- 「ランナー 1 件なのに 0 文字」は**空トークンで起動した個体**の可能性（やること 1）

**測った範囲**

| | シミュレータ | 実機（go-ios） |
|---|---|---|
| 正常系 / `$UDID` 未定義 / 大小文字 / 不在 | 実物 | 実物 |
| 同一 UDID の 2 個体 / それらしい argv を持つだけのプロセス | 合成 | 合成 |
| 起動し直しの所要（ランナー導入済み。`install` を含む初回は別） | `authenticated:true` まで 9〜21 秒（DerivedData 温） | 8〜11 秒 |

**実個体 2 台の同時稼働は未実測。** `-OsAgent -Target device`（CoreDevice が `paired` な端末）の回収も**未実測**
― ホスト側で env を持つのは `xcodebuild` だけで、**そこは `ps` から読めない**（理由は未確認）。
どちらの経路になるかは端末で決まる（`run-ios-e2e.ps1` は `pairingState` が `paired` でなければ入口で止める）。

**トークンの実効**

argv は全ユーザーから、環境変数と 0600 のファイルは同一ユーザーから読める。
**同一ホストの敵対的プロセスに対する防御にはならない**ので、実効は取り違え防止まで。
**隔離が要るならポート番号を分ける。**

**孤児が残るか**

`-OsAgent` 経路（`run-ios-e2e.ps1`）は `finally` から停止処理を通すので、残るのは pwsh 自体が
強制終了された場合と考えられる（未実測）。**`docs/09` の go-ios 手組みは自分で止める手順**なので、
go-ios・`iproxy`・端末上のランナー・端末に入ったままの `.app` が残りうる。
**端末に残ったランナーは `/status` に応答しうるので、次の実行が古い個体へ繋いでも気づけない。**

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
