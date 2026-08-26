# 09. CoreDevice に載らない iOS 実機で OS エージェントを動かす（go-ios 経由・手組み）

**この文書はスクリプトではありません。** キットは go-ios を**配布しません**し、
`run-ios-e2e.ps1` もこの経路を**持っていません**。**必要になった AI が、ここを読んで自分で組み立てる**
ことを前提にした手順書です（**手順書はキットに同梱しますが、外部依存は既定の経路へ持ち込みません**。issue #43）。

**パスの読み方**: 以下は開発リポジトリのパスで書いてあります。**導入先では `uapp_e2e/` 配下**です
（`oslayer/UappOsAgent/` → `uapp_e2e/oslayer/UappOsAgent/` / `config/local.json` → `uapp_e2e/config/local.json`）。

## いつ読むか（**先に条件を満たすことを確かめる**）

`run-ios-e2e.ps1 -OsAgent` が `CoreDevice の pairingState=…` で止まったとき。
**表示は `unsupported` とは限りません** ― CoreDevice が担当しない端末は
`hardwareProperties.udid` が `null` で一覧から引けないため、スクリプトは
**`pairingState=未登録`** と出します（`$pairing` が空のときの表示）。
**`unsupported` と `未登録` のどちらもこの文書の入口です。**

**`Logic Testing on iOS devices is not supported` という文言だけでここへ来てはいけません。**
この文言は**別の原因でも出ます**（2026-08-06 に、下の 3 つをいずれも実機で踏んでいます）:

- テストターゲットの**共有スキームが無い**
- `TEST_TARGET_NAME` に**空文字を明示している**（キーの不在と空文字は別物）
- `-destination-timeout` が短く、USB 端末の列挙に間に合っていない

**進んでよい条件**: **その場で取り直した** `devicectl` の出力で、
**対象が `paired` ではない**ことを確認できたときだけ。

**取得そのものを fail-closed にする** ― 取得前に消す・終了コードを見る・ファイルができたことを見る・
解析できたことを見る、の全部を要求します（`run-ios-e2e.ps1` のガードと同じ形。これを省くと、
CoreDevice が一過性に落ちた回に**前回の古い JSON** を読んで判定が素通りします）。

**先に UDID を決めてください。** 未設定のまま下の判定を回すと、**どの端末にも一致せず
「paired ではない」と出ます**（＝既定の経路が使える端末でも、この文書へ進んでしまう）。

```bash
UDID=<端末の UDID>          # ideviceinfo -k UniqueDeviceID / xcrun devicectl list devices など
test -n "$UDID" || { echo "UDID が空。判定できないので止める"; exit 1; }

rm -f /tmp/dc.json || { echo "古い JSON を消せない"; exit 1; }   # **消せたことまで見る**
xcrun devicectl list devices --json-output /tmp/dc.json || { echo "devicectl の取得に失敗"; exit 1; }
test -f /tmp/dc.json || { echo "JSON が作られていない"; exit 1; }
# **python の終了コードを受ける**（sys.exit は親シェルを止めない。set -e 前提にしない）
python3 - "$UDID" <<'PY' || { echo "ここで止まる（paired だったか、判定できなかった）"; exit 1; }
import json, sys
udid = sys.argv[1]
try:
    devs = json.load(open('/tmp/dc.json'))['result']['devices']
except Exception as e:
    sys.exit(f"JSON を解析できない（判定しない）: {e}")
hit = [x for x in devs if (x.get('hardwareProperties') or {}).get('udid') == udid]
if hit and (hit[0].get('connectionProperties') or {}).get('pairingState') == 'paired':
    sys.exit("paired。この文書は不要 ― 既定の run-ios-e2e.ps1 -OsAgent が使えるはず")
print("paired ではない（この経路の対象）")
PY
```

**`paired` と確認できたら引き返す**のが判定の向きです。逆に、**UDID で引けない**ことも
この状態の特徴なので、それだけで止めてはいけません ―
**CoreDevice が担当しない端末は `hardwareProperties.udid` が `null` になり、UDID では一致しません**
（iPhone 8 / iOS 16.7.16 で実測。`productType` は出るのに `udid` は `None`、
`pairingState` は `unsupported`）。`run-ios-e2e.ps1` のガードが「未登録」を not-paired 側として
扱うのも同じ理由です。

`paired` だったなら**この文書は関係ありません**。既定の経路が使えるはずなので、
落ちているならプロジェクト設定（上の 3 つ）を先に疑ってください。

## 何が起きているのか

**端末の自動化機能は生きています。** 詰まるのはホスト側の 2 点です。

1. **`xcodebuild` の実機の宛先は CoreDevice 由来**なので、CoreDevice が担当しない端末では
   テストの宛先として解決できない（`-showdestinations` には出ることがあるが、
   **出る＝使えるではない** ― 実測: 宛先に出たうえで `xcodebuild test` が落ちた）
2. **Xcode 26 がテストランナーに埋め込む Swift Testing** が、古い iOS に無い dylib を要求して
   起動直後にクラッシュする

1 を go-ios で迂回し、2 を手でフレームワークを同梱して解決します。

### 実測の範囲（断定しないこと）

**iPhone 8（iPhone10,1）/ iOS 16.7.16 の 1 台で通しただけ**です（macOS 26.6 / Xcode 26.6.0 /
go-ios v1.3.2）。同版の別個体・他の iOS 版は未確認。**iOS 17 以降は go-ios が
`ios tunnel start` を要求しますが、その経路は未検証**です。

## 前提

### 端末側（**人に確認してもらう。AI からは設定できない**）

- **設定 → プライバシーとセキュリティ → デベロッパモードが ON**（iOS 16 以降で必須）
- **設定 → デベロッパ → UI オートメーションを有効**
  （**これが無いと、ここまでの手順を全部終えた後で**「起動から約 8 秒で接続が切れる」
  という**原因を示さない症状**に遭います。先に確認する）
- 端末がロック解除されていて、この Mac を「信頼」していること

### ホスト側

- `libimobiledevice`（`ideviceinfo` / `iproxy`）
- 署名できること。**端末がプロビジョニングプロファイルの対象に入っていること**:
  `security cms -D -i <app>/embedded.mobileprovision` の `ProvisionedDevices` に UDID があるか
- **go-ios**（MIT・OSS）。Homebrew の formula は無いのでリリースの zip を取得する。
  **システムへ入れず、作業ディレクトリ内に置く**:

```bash
curl -sSL -o go-ios-mac.zip https://github.com/danielpaulus/go-ios/releases/download/v1.3.2/go-ios-mac.zip
unzip -o go-ios-mac.zip -d ./goios && chmod +x ./goios/ios
./goios/ios version && ./goios/ios list
```

### この手順で使う変数（**最初に決めて最後まで同じものを使う**）

```bash
UDID=<端末の UDID>                           # **上の判定で決めたものと同じ値を使う**
TEAM=<config/local.json の iosTeamId>
AGENT_ID=<エージェントの bundle id>          # 既定は com.uapp.e2e.osagent.runner
RUNNER_ID="${AGENT_ID}.xctrunner"            # install / runtest / uninstall はこちらを使う
DD=<この作業専用の DerivedData ディレクトリ>
```

**`AGENT_ID` を既定のまま使えるとは限りません。** bundle id は Apple の App ID として一意なので、
別チームでは自動署名が通らないことがあります（`oslayer/UappOsAgent/project.yml` に明記あり）。
既定の経路では `run-ios-e2e.ps1 -OsAgentBundleId` / `config/local.json` の `iosOsAgentBundleId`
で上書きします。**変えたなら、以降のすべてのコマンドで変えた値を使うこと**
（ビルドだけ変えて install/runtest が古い ID を触る、という壊れ方をします）。

## 手順

### 1. ランナーを実機向けにビルドする（端末は繋がなくてよい）

```bash
xcodebuild build-for-testing \
  -project oslayer/UappOsAgent/UappOsAgent.xcodeproj -scheme UappOsAgentRunner \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES \
  PRODUCT_BUNDLE_IDENTIFIER="$AGENT_ID"
```

**`-derivedDataPath` は使い回さない。** 既存の DerivedData を使うと、外側の `.app` を署名した後に
`PlugIns/UappOsAgentRunner.xctest` が書き換わり、`codesign --verify` が
`a sealed resource is missing or invalid`、端末側は `0xe8008017
(A signed resource has been added, modified, or deleted.)` で install を拒否する（実測）。

生成物は `$DD/Build/Products/Debug-iphoneos/UappOsAgentRunner-Runner.app`。

### 2. 足りないフレームワークを同梱する

**「足りない」の一次証拠は、実行時の `Library not loaded:` です**（`ios syslog` か
`ios runtest -v` の `outputReceived` に出る）。**`otool -L` は判断材料になりません** ―
出るのは `@rpath` 依存の一覧で、**OS が提供するもの・同梱済みのもの・本当に欠けているものを
区別できない**からです。`otool` は「どこから参照されているか」を辿るために使い、
**足すのは実行時に落ちたものだけ**にします（足したものが**さらに別の依存を要求する**ことが
あるので、`Library not loaded` が出なくなるまで繰り返す）。

iOS 16.7.16 / Xcode 26.6.0 で実際に足りなかったのは 2 つでした（**版が変われば変わります**）:

| 実行時に落ちた参照元 | 不足していたもの | Xcode 内の実体 |
|---|---|---|
| `Frameworks/Testing.framework/Testing` | `lib_TestingInterop.dylib` | `<Xcode>/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/` |
| `Frameworks/libXCTestSwiftSupport.dylib` | `_Testing_Foundation.framework` | `<Xcode>/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/Frameworks/` |

**足したものは記録する**（次の署名でそのまま使う。**決め打ちの 2 個にしない** ―
版が変われば 3 個目が要るので、記録しないと署名から漏れて `0xe8008017` で install が拒否される）:

```bash
A="$DD/Build/Products/Debug-iphoneos/UappOsAgentRunner-Runner.app"
ADDED=()                                  # 足したもののパスをここへ積む

cp <Xcode>/.../usr/lib/lib_TestingInterop.dylib "$A/Frameworks/"
ADDED+=("$A/Frameworks/lib_TestingInterop.dylib")

cp -R <Xcode>/.../Library/Frameworks/_Testing_Foundation.framework "$A/Frameworks/"
rm -rf "$A/Frameworks/_Testing_Foundation.framework/_CodeSignature"   # 元の署名は捨てて付け直す
ADDED+=("$A/Frameworks/_Testing_Foundation.framework")
```

**OS が提供しているものをコピーしない。** dyld のエラーに出ていないものを足すと、
署名だけ増えて問題は変わらず、原因の切り分けが濁ります。

### 3. 署名し直す

**署名 ID は Team で絞る。** `find-identity` の先頭を無条件に採ると、
`$TEAM` とも埋め込みプロファイルとも無関係な証明書で署名しうる:

```bash
security find-identity -v -p codesigning | grep "$TEAM"    # 1 行に絞れることを確認する
```

複数一致するなら**止めて人に選んでもらう**（黙って先頭を採らない）。

```bash
ID=<上で絞り込んだハッシュ>
codesign -d --entitlements :- "$A" > ent.plist
test -s ent.plist || { echo "entitlements が空。空のまま署名すると権限が黙って落ちる"; exit 1; }
for f in "${ADDED[@]}"; do                        # **記録した全部**を内側から署名する
  codesign -f -s "$ID" --timestamp=none "$f" || { echo "署名に失敗: $f"; exit 1; }
done
codesign -f -s "$ID" --timestamp=none --entitlements ent.plist "$A"
codesign --verify --deep --strict "$A"                      # valid on disk まで出ること
codesign -d --entitlements :- "$A" | grep -q "$TEAM" || echo "Team が一致しない。署名 ID を見直す"
```

### 4. 入れる

```bash
./goios/ios install --path "$A" --udid "$UDID"
./goios/ios apps --udid "$UDID" | grep "$RUNNER_ID"    # 入ったことを確認
```

### 5. 起こす

**先に対照（すぐ終わるテスト）を通す。** これが通らないうちに常駐テストへ進むと、
「起動しない」のか「常駐の作り方の問題」なのかが分からなくなる。

```bash
./goios/ios runtest --bundle-id="$RUNNER_ID" --test-runner-bundle-id="$RUNNER_ID" \
  --xctest-config=UappOsAgentRunner.xctest \
  --test-to-run=UappOsAgent/testTrivial --udid "$UDID" -v
# → Test Suite 'UappOsAgent' passed
```

通ったら常駐エージェントを起こす。**PID を必ず保存する**（後始末で使う）。
**go-ios の `--env` は接頭辞なしで届く**（`xcodebuild` 経由で要る `TEST_RUNNER_` を付けない）:

```bash
TOKEN=$(openssl rand -hex 16)            # 実行のたびに変える。ログや追跡ファイルへ書かない
./goios/ios runtest --bundle-id="$RUNNER_ID" --test-runner-bundle-id="$RUNNER_ID" \
  --xctest-config=UappOsAgentRunner.xctest \
  --test-to-run=UappOsAgent/testRunAgent \
  --env=UAPP_OS_AGENT_PORT=8200 --env=UAPP_OS_AGENT_TOKEN="$TOKEN" \
  --udid "$UDID" & AGENT_PID=$!
iproxy 8201:8200 -u "$UDID" & IPROXY_PID=$!
```

**トークンの限界を理解しておくこと。** エージェント側の意図は「ループバックは LAN から
隔離するだけで認証ではない。同じマシンの別プロセス・別ユーザーからは届くのでトークンで認証する」
ですが、**この渡し方ではトークンが go-ios の argv に載り、`ps` から見えます**。
つまり**同一ホストの敵対的プロセスに対する防御にはなりません**。実効は
「古いトンネルの残骸や別個体へ繋いでいないかの取り違え防止」までです。

### 6. 疎通を確かめる

```bash
curl -sS -H "X-Uapp-Token: $TOKEN" http://127.0.0.1:8201/status
# {"agent":"uapp-os-agent/1.0","platform":"iOS","screen":{...},"authenticated":true,"ok":true}
```

**`authenticated: true` まで見る。**

## 動作確認（対照込み）

### **HTTP の 200 を「操作が効いた証拠」にしない**

`/tap` と `/swipe` は **XCUI の API を呼んだ直後に無条件で `{"ok":true}` を返します**
（`UappOsAgent.swift`）。座標がどこであっても、画面上で何も起きなくても 200 です。
**効果は必ず観測で確かめること**:

- `/screenshot` を操作の前後で撮って**画像として比べる**
- 状態が変わったことを別の API で確かめる（例: `/alert` が 404 になった）

### 実際のシステムダイアログを押すところまで（実測）

**ダイアログを出すだけの使い捨てアプリ**を作って確かめました（`xcodegen` で最小の SwiftUI アプリ。
起動時に `NWBrowser` でローカルネットワーク要求、ボタンで `ATTrackingManager` の要求）。
エージェントを起こしたまま `ios launch <プローブ>` で起動します。

| 操作 | 観測できた結果 |
|---|---|
| `/alert` に**存在しないボタン名**を渡す | 404 ＋ `available: ["許可しない","許可"]` ＝**実在のダイアログを認識して列挙できる** |
| `/alert` `{"button":"許可"}` | 200。**スクショでダイアログが消えていることを確認** |
| 押した後にもう一度 `/alert` | 404「システムアラートがありません」（**この遷移が押せた証拠**） |
| `/tap` でアプリ内のボタンを押して ATT を出す | **その後 `/alert` にボタンが現れたこと**で効果を確認（200 ではなく） |
| その ATT を `/alert` で押す | 200 → 直後の `/alert` は 404 |
| 一連の後の `/status` | 生存（**ここで死ぬ既知の型がある**） |

**ボタン名は OS の版・言語で変わります。** 決め打ちで押さず、
**存在しない名前を渡して `available` を得てから選ぶ**のが安全です。

## 後始末

**PID で止める。`pkill -f` のような広いパターンを使わない**（同じ文字列を含む
無関係な実行まで殺します。実際にそれをやりかけました）:

```bash
curl -sS -H "X-Uapp-Token: $TOKEN" -X POST http://127.0.0.1:8201/stop
kill "$IPROXY_PID" "$AGENT_PID" 2>/dev/null
./goios/ios ps --udid "$UDID" | grep xctrunner        # 0 件になること
./goios/ios uninstall "$RUNNER_ID" --udid "$UDID"     # 端末から消す場合
```

**途中で失敗したときも同じものを止める。** 残りうるのは
**ホスト側の go-ios と iproxy**・**端末上のランナー**・**端末に入ったままの `.app`** の 3 つです。
**ランナーを入れっぱなしにするなら記録に残すこと** ― 端末に残ったランナーは `/status` に
応答しうるので、次の実行が古い個体へ繋いでも気づけません。

## 詰まったときの切り分け

**症状から原因を断定しない。** 観測できることだけで表を引く。

| 観測 | 考えられること | 次の一手 |
|---|---|---|
| `install` が `0xe8008017` | 署名の封が壊れている（DerivedData の使い回しが典型） | `codesign --verify --deep --strict` を先に通す |
| `install` が署名関連で拒否される | プロファイルに端末が入っていない／Team 不一致 | `embedded.mobileprovision` の `ProvisionedDevices` と `application-identifier` を見る |
| ランナーが起動直後に消える | 依存 dylib の不足が有力 | `ios syslog` に `Library not loaded:` が出ていないか |
| go-ios が `broken pipe` で `_IDE_startExecutingTestPlanWithProtocolVersion` に失敗 | **テストバンドルの読み込み失敗が先に起きている**ことがある | `-v` を付けて `didFailToBootstrap` と `dlopen` の行を探す |
| 起動から 8 秒前後で `connection was invalidated` | 端末側の「UI オートメーションを有効」未設定の既知の型 | 端末の設定を人に確認してもらう |
| `Logic Testing on iOS devices is not supported` | **CoreDevice とは限らない**（冒頭参照） | まず `devicectl` の `pairingState` を取り直す。`paired` ならこの文書は無関係 |

## やってはいけないこと

- **`run-ios-e2e.ps1` の `pairingState` ガードを外さない。** あれは正しく効いている
  （`-showdestinations` に出ても `xcodebuild test` は落ちる、を実測済み）。
  この経路を使うなら**ガードを迂回する別の入口**として組み、既定の経路は変えない
- **HTTP の 200 を成功の証拠にしない**（上記）
- **go-ios をキットの必須依存にしない。** 依存を増やす判断は別（issue #43 で保留中）
- **フレームワークを決め打ちで並べない。** 実行時に落ちたものだけを足す
- **`pkill -f` で後始末しない。** PID を保存して PID で止める
- **AI 側から実機を再起動しない。** 物理操作（抜き差し・ロック解除・設定変更）は人に依頼する
