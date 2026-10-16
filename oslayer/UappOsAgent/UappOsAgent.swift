// uapp_e2e OS レイヤーエージェント（XCUITest 常駐サーバー）
//
// **これは E2EBridge（アプリ内計装）の置き換えではなく補完**。
// ブリッジは Unity の中しか見えない（外部ブラウザ・システムダイアログ・WebView・
// ソフトキーボードは `dump` にも `tap` にも現れず、計装側のスクショにも写らない）。
// このエージェントは XCUITest として**アプリの外側**から OS を操作するので、その穴を埋める。
// Android における adb / uiautomator に相当する役割。
//
// 仕組み: **終わらないテスト**の中で HTTP サーバーを立て、ホストからのコマンドで
// XCUITest の API を呼ぶ（WebDriverAgent と同じ方式）。ホストからの到達は
// シミュレータならローカルポート直、実機は `iproxy` で USB トンネルを張る。
//
// **Unity の要素は見えない**（Unity は Metal のビュー 1 枚として現れ、アクセシビリティ
// ツリーに UI が出ない）。Unity の要素は**座標**で操作し、要素単位の操作はブリッジ側（path・hittable 判定つき）を使う。
// **アクセシビリティの要素（/elements・/element/*・/tree）は Unity の外**（WebView・Safari・システム UI・
// ネイティブのダイアログ）のためのもの（issue #85）。
//
// **接続先の取り違えを防ぐためトークンで認証する**（`UAPP_OS_AGENT_TOKEN`）。
// 並行実行や古いトンネルが同じポートを握っていると、別個体のスクショ・タップへ進んで
// 偽の緑になるため、**トークンが設定されているときは全エンドポイントで一致を要求**し、
// `/status` の `authenticated` で「認証つきの正しい相手か」をホスト側が判定できるようにする。
//
// 提供するコマンド（すべて `X-Uapp-Token` ヘッダが要る。トークン未設定時のみ無認証）:
//   GET  /status                        … 生存確認・画面サイズ・認証状態・対応機能（features）・端末の向き
//   GET  /screenshot                    … 画面全体の PNG（**OS が合成した結果**）
//   POST /tap      {"x":…,"y":…[,"bundleId":…]} … 正規化座標（0〜1・左上原点）でタップ
//   POST /swipe    {"x1":…,…[,"bundleId":…]}    … 正規化座標でスワイプ
//        **bundleId を省くと SpringBoard（iPhone では回転しない＝縦。iPad は未実測）基準**。渡すとそのアプリの画面基準で押す
//        （横画面のアプリはこちらでないと当たらない。issue #80）。渡したときは前面でなければ 409
//   POST /type     {"bundleId":…,"text":…} … **対象アプリを明示**して文字入力
//   POST /alert    {"button":"…"}       … システムアラートのボタンを押す
//   POST /activate {"bundleId":"…"}     … 実行中のアプリを前面へ（**未起動なら拒否**）
//   POST /orientation {"orientation":"…"} … 端末の向きを変える（portrait / portraitUpsideDown /
//        landscapeLeft / landscapeRight）。**変わるのは端末の向きで、アプリが回るかはアプリ次第**。
//        応答は書き込んだあとに読み直した向き（issue #83）
//   以下は issue #85:
//   POST /app/state | /app/launch | /app/terminate {"bundleId", …} … アプリの状態・起動（引数・環境変数）・終了
//   POST /elements {query…}             … アクセシビリティの要素を探す（snapshot を 1 回取って Swift で照合）
//   POST /element/tap | /element/wait | /element/type {query…} … 要素を押す・待つ・文字を入れる
//   POST /tree {"bundleId"?}            … アクセシビリティツリー（debugDescription。text/plain）
//   POST /doubletap | /longpress {"x","y",…} / POST /pinch {"bundleId","scale",…} … ジェスチャ
//   POST /press {"button"} / POST /open-url {"url"} … 端末のボタン・URL を開く
//   POST /stop                          … エージェントを終了
import Foundation
import XCTest

/// `Result` の失敗側に応答をそのまま載せるため（issue #85 の補助関数）
extension HttpResponse: Error {}

final class UappOsAgent: XCTestCase {

    /// ホストから接続するポート。実機は iproxy でこのポートへトンネルする。
    /// **ホスト側は `TEST_RUNNER_UAPP_OS_AGENT_PORT` として渡す** — xcodebuild は
    /// 素の環境変数をテストランナーへ渡さず、この接頭辞付きだけが（接頭辞を外して）届く
    private static var port: UInt16 {
        if let raw = ProcessInfo.processInfo.environment["UAPP_OS_AGENT_PORT"],
           let value = UInt16(raw), value > 0 {
            return value
        }
        return 8200
    }

    /// 認証トークン（ホストが起動時に注入する）。未設定なら無認証で動く（手動デバッグ用）。
    private static var token: String? {
        let raw = ProcessInfo.processInfo.environment["UAPP_OS_AGENT_TOKEN"]
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// **対照実験用**: すぐ終わる普通の UI テスト。これが通れば端末と Xcode の組み合わせは
    /// 健全で、問題は「終わらないテスト」という作り方の側にあると切り分けられる
    func testTrivial() throws {
        let frame = springboard.frame
        NSLog("[UappOsAgent] trivial: \(Int(frame.width))x\(Int(frame.height))")
        XCTAssertGreaterThan(frame.width, 0)
    }

    /// **テストを終わらせない**。終了するとサーバーも落ちるため、停止要求が来るまで待ち続ける。
    func testRunAgent() throws {
        // **過去の切り分け用の残置**。実機で「起動直後に接続が切れる」現象の原因は、
        // 端末側の「設定 → デベロッパ → UI オートメーションを有効」が OFF だったこと
        // （2026-08-06 に判明）。待ち方でも HTTP サーバーでもなかったが、同種の症状が
        // 再発したときに「待つこと自体」と「サーバー」を分ける経路として残す
        if ProcessInfo.processInfo.environment["UAPP_OS_AGENT_NOSERVER"] == "1" {
            NSLog("[UappOsAgent] no-server probe: idling (main=\(Thread.isMainThread))")
            // **RunLoop を回さずに待つ**。テストがメイン以外のスレッドで走っているなら、
            // こちらの待ち方ならメインの RunLoop が自然に回り続ける
            let end = Date().addingTimeInterval(180)
            while Date() < end { Thread.sleep(forTimeInterval: 0.25) }
            NSLog("[UappOsAgent] no-server probe: survived")
            return
        }

        // **ジェスチャ単体の対照実験**（2026-08-07 に実機で `/tap`・`/swipe` を送ると
        // ランナーが落ちる件の切り分け用。シミュレータでは同じ操作が通る）。
        // HTTP を挟まずにジェスチャだけを送り、呼び出し経路を選べる:
        //   `direct`   … テストのスレッドから直接呼ぶ（サーバーも `main.sync` も通らない）
        //   `dispatch` … 別キューから `DispatchQueue.main.sync` で呼ぶ（**常駐時と同じ経路**）
        // 3 つのログ（sending / returned / survived）の**どこで途切れるか**で、
        // 「ジェスチャ API そのもの」「`main.sync` の経路」「送った後の生存」を分けられる。
        // **どちらのモードでも落ちるなら HTTP サーバーは無関係**と言い切れる
        let probeMode = ProcessInfo.processInfo.environment["UAPP_OS_AGENT_GESTURE_PROBE"] ?? ""
        if probeMode == "direct" || probeMode == "dispatch" {
            let seconds = Double(ProcessInfo.processInfo.environment["UAPP_OS_AGENT_PROBE_SECONDS"] ?? "") ?? 60
            NSLog("[UappOsAgent] gesture probe: mode=\(probeMode) idle=\(Int(seconds))s (main=\(Thread.isMainThread))")
            let deadline = Date().addingTimeInterval(seconds)
            if probeMode == "direct" {
                performProbeGesture()
                while Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
            } else {
                // 常駐時と同じ形にする: ネットワーク用の直列キューから `main.sync` で呼び、
                // 呼び出し側が塞がっている間、メインは RunLoop を回して待つ。
                // **1 秒遅らせる**のは、待ち側が回り始めてから送るため（送信が先だと
                // メインが RunLoop に入る前で、常駐時と条件が変わる）
                let queue = DispatchQueue(label: "uapp.os.agent.probe")
                queue.asyncAfter(deadline: .now() + 1) {
                    NSLog("[UappOsAgent] gesture probe: calling main.sync")
                    DispatchQueue.main.sync { self.performProbeGesture() }
                    NSLog("[UappOsAgent] gesture probe: main.sync returned")
                }
                while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            }
            NSLog("[UappOsAgent] gesture probe: survived")
            return
        }

        let server = HttpServer(port: UappOsAgent.port, token: UappOsAgent.token)
        server.handler = { [weak self] request in
            guard let self = self else { return HttpResponse(status: 500, json: ["error": "agent gone"]) }
            return self.handle(request)
        }
        try server.start()
        NSLog("[UappOsAgent] listening on \(UappOsAgent.port) (auth=\(UappOsAgent.token != nil))")

        while !server.shouldStop {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        server.stop()
        NSLog("[UappOsAgent] stopped")
    }

    // MARK: - コマンド

    private func handle(_ request: HttpRequest) -> HttpResponse {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            let frame = springboard.frame
            return HttpResponse(status: 200, json: [
                "ok": true,
                "agent": "uapp-os-agent/1.0",
                "platform": "iOS",
                // **ホスト側が「認証つきの正しい相手か」を判定するための旗**。
                // トークン未設定のエージェント（別実行の残骸など）は false を返すので、
                // ホストは自分が起動した個体でないと分かる
                "authenticated": UappOsAgent.token != nil,
                // **SpringBoard の frame**（iPhone では回転しない。iPad は未実測）。横画面のアプリの画面サイズとしては使わない
                "screen": ["w": Int(frame.width), "h": Int(frame.height)],
                // ホストが**押す前に**対応を確かめるための一覧。古いエージェントは bundleId を
                // 黙って無視して SpringBoard 基準で押すので、応答を見てからでは遅い（issue #80）。
                // orientation は一覧として見せるだけ（古い版は /orientation を 404 で返し、何も起きない）
                "features": ["bundleId", "orientation", "app", "elements", "gestures", "press", "openUrl", "typeFocusCheck"],
                // 端末の向き（XCUIDevice）。一度も回していないと unknown 等を返しうる
                "orientation": UappOsAgent.orientationName(XCUIDevice.shared.orientation),
            ])

        case ("GET", "/screenshot"):
            // XCUIScreen は**画面の合成結果**を撮る（アプリの描画に限らない）
            let png = XCUIScreen.main.screenshot().pngRepresentation
            return HttpResponse(status: 200, contentType: "image/png", body: png)

        case ("POST", "/tap"):
            guard let x = request.jsonDouble("x"), let y = request.jsonDouble("y") else {
                return HttpResponse(status: 400, json: ["error": "x, y (0..1) が必要です"])
            }
            // **判定順は 座標 → bundleId**（両方不正なら座標の 400）
            let base: XCUIApplication
            let baseName: String
            switch bundleIdParam(request) {
            case .absent:
                base = springboard; baseName = "springboard"
            case .invalid(let response):
                return response
            case .value(let bundleId):
                let app = XCUIApplication(bundleIdentifier: bundleId)
                if let response = notForegroundResponse(app) { return response }
                base = app; baseName = bundleId
            }
            coordinate(x, y, on: base).tap()
            // base は**送られた bundleId のエコー**（どちらの基準で押したかを呼び手が確かめる）
            return HttpResponse(status: 200, json: ["ok": true, "base": baseName])

        case ("POST", "/swipe"):
            guard let x1 = request.jsonDouble("x1"), let y1 = request.jsonDouble("y1"),
                  let x2 = request.jsonDouble("x2"), let y2 = request.jsonDouble("y2") else {
                return HttpResponse(status: 400, json: ["error": "x1, y1, x2, y2 (0..1) が必要です"])
            }
            let duration = request.jsonDouble("duration") ?? 0.2
            let base: XCUIApplication
            let baseName: String
            switch bundleIdParam(request) {
            case .absent:
                base = springboard; baseName = "springboard"
            case .invalid(let response):
                return response
            case .value(let bundleId):
                let app = XCUIApplication(bundleIdentifier: bundleId)
                if let response = notForegroundResponse(app) { return response }
                base = app; baseName = bundleId
            }
            // **始点と終点は同じ基準で作る**（基準を混ぜない）
            coordinate(x1, y1, on: base).press(forDuration: duration, thenDragTo: coordinate(x2, y2, on: base))
            return HttpResponse(status: 200, json: ["ok": true, "base": baseName])

        case ("POST", "/type"):
            // **対象アプリを明示させる**。`typeText` は「呼び出した要素かその子孫に
            // キーボードフォーカスがあること」が Apple の契約なので、SpringBoard へ
            // 送っても対象アプリの入力欄には入らない（設計を誤っていた箇所）
            guard let text = request.jsonString("text") else {
                return HttpResponse(status: 400, json: ["error": "text が必要です"])
            }
            let app: XCUIApplication
            switch bundleIdParam(request) {
            case .absent:
                return HttpResponse(status: 400, json: [
                    "error": "bundleId が必要です（入力欄を持つアプリを明示してください）"])
            case .invalid(let response):
                return response
            case .value(let bundleId):
                app = XCUIApplication(bundleIdentifier: bundleId)
            }
            // 前面の確認は /tap・/swipe と同じ関数を通す（文言と state の表し方を揃える）
            if let response = notForegroundResponse(app) { return response }
            // **フォーカスが無いまま typeText を呼ばない**。呼ぶと XCTest の失敗として記録され、
            // 200 を返したあとエージェントごと終了した（issue #81）
            // **フォーカスを持つ要素が見えるときだけ入力する**。キーボードが出ていても、フォーカスの要素が
            // アクセシビリティに見えないまま typeText を呼ぶと XCTest の失敗になりエージェントが終了する
            // （シミュレータの Unity の入力欄で実測。2026-10-16）
            if let refusal = typeRefusal(in: app) { return refusal }
            app.typeText(text)
            return HttpResponse(status: 200, json: ["ok": true])

        case ("POST", "/alert"):
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: request.jsonDouble("timeout") ?? 5) else {
                return HttpResponse(status: 404, json: ["error": "システムアラートがありません"])
            }
            if let label = request.jsonString("button") {
                let button = alert.buttons[label]
                guard button.exists else {
                    return HttpResponse(status: 404, json: [
                        "error": "ボタンがありません: \(label)",
                        "available": alert.buttons.allElementsBoundByIndex.map { $0.label },
                    ])
                }
                button.tap()
            } else {
                alert.buttons.firstMatch.tap()
            }
            return HttpResponse(status: 200, json: ["ok": true])

        case ("POST", "/activate"):
            // 空文字・非文字列の 400 だけ揃える。**前面の確認は通さない**
            // （/activate は背面のアプリを前面へ出すための API。前面確認を入れると機能が壊れる）
            let app: XCUIApplication
            switch bundleIdParam(request) {
            case .absent:
                return HttpResponse(status: 400, json: ["error": "bundleId が必要です"])
            case .invalid(let response):
                return response
            case .value(let bundleId):
                app = XCUIApplication(bundleIdentifier: bundleId)
            }
            // **未起動なら拒否する**。`activate()` は未起動のアプリを**起動してしまう**
            // （Apple の仕様。「起動し直さない」のは既に動いている場合だけ）。
            // 黙って起動すると、クラッシュや OS による終了で状態が失われたことを隠し、
            // ブリッジ接続が切れているのに新しいアプリで続行してしまう
            guard app.state != .notRunning && app.state != .unknown else {
                return HttpResponse(status: 409, json: [
                    "error": "アプリが起動していません（state=\(app.state.rawValue)）。" +
                             "activate は起動中のアプリを前面へ出すためのもので、" +
                             "ここで起動すると状態が失われたことを隠してしまうため拒否します"])
            }
            app.activate()
            return HttpResponse(status: 200, json: ["ok": true, "state": app.state.rawValue])

        case ("POST", "/orientation"):
            // **端末を回したことにする**（XCUIDevice.shared.orientation）。アプリの UI の向きとは直接結び付かず、
            // アプリが回るのはその向きに対応している場合だけ。効果はホストがアプリ側で確かめる（issue #83）。
            // 向きは端末全体の状態なので bundleId は取らず、前面の確認もしない
            guard let name = request.jsonString("orientation"),
                  let target = UappOsAgent.settableOrientations[name] else {
                return HttpResponse(status: 400, json: [
                    "error": "orientation は次のどれかを文字列で指定してください（大小文字を区別）",
                    "allowed": UappOsAgent.settableOrientationNames,
                ])
            }
            XCUIDevice.shared.orientation = target
            // **送った値のエコーにしない**。読み直した値を返し、効いたかの判定はホストに任せる
            return HttpResponse(status: 200, json: [
                "ok": true, "orientation": UappOsAgent.orientationName(XCUIDevice.shared.orientation)])

        case ("POST", "/app/state"):
            switch requiredApp(request) {
            case .failure(let response): return response
            case .success(let app):
                return HttpResponse(status: 200, json: ["state": app.state.rawValue, "stateName": UappOsAgent.stateName(app.state)])
            }

        case ("POST", "/app/launch"):
            switch requiredApp(request, forLifecycle: true) {
            case .failure(let response): return response
            case .success(let app):
                if let raw = request.json["arguments"] {
                    guard let arguments = raw as? [String] else {
                        return HttpResponse(status: 400, json: ["error": "arguments は文字列の配列で指定してください"])
                    }
                    app.launchArguments = arguments
                }
                if let raw = request.json["environment"] {
                    guard let environment = raw as? [String: String] else {
                        return HttpResponse(status: 400, json: ["error": "environment は文字列から文字列への辞書で指定してください"])
                    }
                    app.launchEnvironment = environment
                }
                // **動いていれば終了してから起動し直す**（XCUIApplication.launch の仕様）。
                // 起動に失敗すると XCTest がテストを止める（＝エージェントが終了する）。事前に確かめる手段は無い（残る限界）
                app.launch()
                return HttpResponse(status: 200, json: ["ok": true, "state": app.state.rawValue, "stateName": UappOsAgent.stateName(app.state)])
            }

        case ("POST", "/app/terminate"):
            switch requiredApp(request, forLifecycle: true) {
            case .failure(let response): return response
            case .success(let app):
                if app.state != .notRunning && app.state != .unknown { app.terminate() }
                return HttpResponse(status: 200, json: ["ok": true, "state": app.state.rawValue, "stateName": UappOsAgent.stateName(app.state)])
            }

        case ("POST", "/elements"):
            switch elementBase(request) {
            case .failure(let response): return response
            case .success(let base):
                let filter: ElementFilter
                switch elementFilter(request) {
                case .failure(let response): return response
                case .success(let value): filter = value
                }
                let limit = UappOsAgent.boundedInt(request.jsonDouble("limit"), fallback: 50, range: 1...200)
                let root: XCUIElementSnapshot
                do { root = try base.app.snapshot() } catch {
                    return HttpResponse(status: 500, json: ["error": "snapshot を取れません: \(error)"])
                }
                var matched: [XCUIElementSnapshot] = []
                collect(root, filter: filter, into: &matched)
                let frame = root.frame
                let elements = matched.prefix(limit).map { UappOsAgent.describe($0, base: frame) }
                return HttpResponse(status: 200, json: ["count": matched.count, "elements": elements])
            }

        case ("POST", "/element/tap"):
            switch resolveElement(request) {
            case .failure(let response): return response
            case .success(let element):
                guard element.isHittable else { return notHittableResponse(element) }
                // **要約は押す前に取る**（押すと消える要素＝アラートのボタン・画面を移るボタンの属性を、押したあとに読むと
                // XCTest の失敗になりエージェントが止まりうる）
                let summary = UappOsAgent.summary(element)
                element.tap()
                return HttpResponse(status: 200, json: ["ok": true, "element": summary])
            }

        case ("POST", "/element/wait"):
            let state = request.json["state"] == nil ? "exists" : (request.jsonString("state") ?? "")
            guard ["exists", "gone", "hittable"].contains(state) else {
                return HttpResponse(status: 400, json: ["error": "state は exists / gone / hittable のどれかを指定してください（大小文字を区別）"])
            }
            switch elementQuery(request) {
            case .failure(let response): return response
            case .success(let element):
                let timeout = clampedTimeout(request)
                let deadline = Date().addingTimeInterval(timeout)
                // waitForNonExistence は使わない（導入された Xcode の版に依らないため）。exists / isHittable を見て待つ
                func reached() -> Bool {
                    switch state {
                    case "gone": return !element.exists
                    case "hittable": return element.exists && element.isHittable
                    default: return element.exists
                    }
                }
                while true {
                    if reached() { return HttpResponse(status: 200, json: ["ok": true, "state": state]) }
                    if Date() >= deadline { break }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                return HttpResponse(status: 408, json: [
                    "error": "時間切れです（\(timeout) 秒。待った状態: \(state)）",
                    "exists": element.exists, "hittable": element.exists && element.isHittable])
            }

        case ("POST", "/element/type"):
            guard let text = request.jsonString("text") else {
                return HttpResponse(status: 400, json: ["error": "text が必要です"])
            }
            let clear = (request.json["clear"] as? Bool) ?? false
            switch resolveElement(request) {
            case .failure(let response): return response
            case .success(let element):
                guard element.isHittable else { return notHittableResponse(element) }
                let app = baseApp(request)
                let summary = UappOsAgent.summary(element)
                let target = element.frame
                element.tap()
                // **押した要素（かその子）にフォーカスが来たかを確かめ、フォーカスを持つ要素へ入力する**。
                // 「アプリのどこかにフォーカスがある」だけだと、別の入力欄がフォーカスを持ったまま押しても移らない要素を
                // 指定したときに、typeText が XCTest の失敗になりエージェントが止まりうる（#81 と同じ型）
                func focusedInTarget() -> XCUIElement? {
                    let focused = focusedElement(in: app)
                    guard focused.exists, target.insetBy(dx: -1, dy: -1).contains(focused.frame) else { return nil }
                    return focused
                }
                let deadline = Date().addingTimeInterval(2)
                var field = focusedInTarget()
                while field == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.1); field = focusedInTarget() }
                guard let input = field else {
                    return HttpResponse(status: 409, json: ["error": "要素を押しましたが、その要素にキーボードのフォーカスが来ません", "element": summary])
                }
                if clear {
                    let placeholder = input.placeholderValue ?? ""
                    let current = (input.value as? String) ?? ""
                    // **値がプレースホルダーと同じでも消す**（同じ文字列の実際の値かもしれない。空欄に削除キーを送っても害は無い）
                    if !current.isEmpty {
                        // 右端寄りを押してカーソルを末尾へ寄せてから、値の長さぶん削除キーを送る
                        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4))
                    }
                    // **消えたか読み直す**。残っていれば入力しない（黙って混ざった値を入れない）
                    let after = input.exists ? ((input.value as? String) ?? "") : ""
                    // **消したあとの値がプレースホルダーと同じなら、消す前の値にかかわらず判別できない**
                    // （空欄なのか、部分的に消えた残りがたまたまプレースホルダーと同じ文字列なのか。例: "prefixguest" → "guest"）
                    if input.exists && !placeholder.isEmpty && after == placeholder {
                        return HttpResponse(status: 409, json: [
                            "error": "値がプレースホルダーと同じで、空欄か既存の値かを判別できません。入力していません（空欄なら clear を付けずに入れる）",
                            "remaining": after])
                    }
                    guard input.exists, after.isEmpty else {
                        return HttpResponse(status: 409, json: [
                            "error": "既存の値を消し切れませんでした（カーソル位置・消去ボタン・伏せ字の可能性）。入力していません",
                            "remaining": after])
                    }
                }
                input.typeText(text)
                // 入力で要素が消えることがある（確定で画面が移る等）ので、あるときだけ読む
                let value: Any = input.exists ? ((input.value as? String) ?? NSNull()) : NSNull()
                return HttpResponse(status: 200, json: ["ok": true, "value": value])
            }

        case ("POST", "/tree"):
            switch elementBase(request) {
            case .failure(let response): return response
            case .success(let base):
                // 人と AI が読むデバッグ用（形式は Apple の実装依存。機械で解析しない）
                return HttpResponse(status: 200, contentType: "text/plain; charset=utf-8",
                                    body: Data(base.app.debugDescription.utf8))
            }

        case ("POST", "/doubletap"), ("POST", "/longpress"):
            guard let x = request.jsonDouble("x"), let y = request.jsonDouble("y") else {
                return HttpResponse(status: 400, json: ["error": "x, y (0..1) が必要です"])
            }
            var duration = 1.0
            if request.path == "/longpress" {
                duration = request.jsonDouble("duration") ?? 1.0
                guard duration > 0 && duration <= 10 else {
                    return HttpResponse(status: 400, json: ["error": "duration は 0 より大きく 10 以下で指定してください（長い操作の間は他の要求も止まるため）"])
                }
            }
            let base: XCUIApplication
            let baseName: String
            switch bundleIdParam(request) {
            case .absent:
                base = springboard; baseName = "springboard"
            case .invalid(let response):
                return response
            case .value(let bundleId):
                let app = XCUIApplication(bundleIdentifier: bundleId)
                if let response = notForegroundResponse(app) { return response }
                base = app; baseName = bundleId
            }
            let point = coordinate(x, y, on: base)
            if request.path == "/doubletap" { point.doubleTap() } else { point.press(forDuration: duration) }
            return HttpResponse(status: 200, json: ["ok": true, "base": baseName])

        case ("POST", "/pinch"):
            let app: XCUIApplication
            switch bundleIdParam(request) {
            case .absent:
                return HttpResponse(status: 400, json: ["error": "bundleId が必要です（アプリの要素に対してピンチする）"])
            case .invalid(let response):
                return response
            case .value(let bundleId):
                app = XCUIApplication(bundleIdentifier: bundleId)
            }
            if let response = notForegroundResponse(app) { return response }
            guard let scale = request.jsonDouble("scale"), scale >= 0.1, scale <= 10 else {
                return HttpResponse(status: 400, json: ["error": "scale は 0.1〜10 で指定してください"])
            }
            // velocity の符号の規則は資料に無いので検査しない（省くと scale に合わせる）
            let velocity = request.jsonDouble("velocity") ?? (scale > 1 ? 1 : -1)
            app.pinch(withScale: CGFloat(scale), velocity: CGFloat(velocity))
            return HttpResponse(status: 200, json: ["ok": true, "scale": scale, "velocity": velocity])

        case ("POST", "/press"):
            guard let name = request.jsonString("button") else {
                return HttpResponse(status: 400, json: ["error": "button は home / volumeUp / volumeDown のどれかを指定してください"])
            }
            switch name {
            case "home":
                XCUIDevice.shared.press(.home)
            case "volumeUp", "volumeDown":
                #if targetEnvironment(simulator)
                return HttpResponse(status: 400, json: ["error": "音量ボタンはシミュレータでは使えません（XCUITest の実機専用の API）"])
                #else
                XCUIDevice.shared.press(name == "volumeUp" ? .volumeUp : .volumeDown)
                #endif
            default:
                return HttpResponse(status: 400, json: ["error": "button は home / volumeUp / volumeDown のどれかを指定してください（大小文字を区別）"])
            }
            return HttpResponse(status: 200, json: ["ok": true, "button": name])

        case ("POST", "/open-url"):
            guard let raw = request.jsonString("url"), !raw.isEmpty,
                  let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty else {
                return HttpResponse(status: 400, json: ["error": "url はスキームつきの URL を指定してください（例: https://… / myapp://…）"])
            }
            if #available(iOS 16.4, *) {
                // 独自スキームでは初回に「開きますか」のダイアログが出て戻らないことがある（残る限界）
                XCUIDevice.shared.system.open(url)
                return HttpResponse(status: 200, json: ["ok": true])
            }
            return HttpResponse(status: 501, json: ["error": "URL を開く API は iOS 16.4 以降でのみ使えます"])

        case ("POST", "/stop"):
            return HttpResponse(status: 200, json: ["ok": true], stopServer: true)

        default:
            return HttpResponse(status: 404, json: ["error": "unknown: \(request.method) \(request.path)"])
        }
    }

    /// 対照実験で送るジェスチャ。**副作用の小さいものを既定にする** —
    /// ホーム画面のページ送り（縦スワイプではなく上下だが、アプリは起動しない）。
    /// アプリを起動してしまうと「ランナーが背面へ回った」という別の要因が混ざる。
    /// `UAPP_OS_AGENT_PROBE_GESTURE=tap` で tap 側も試せる（画面上端付近＝ホーム画面では無反応）
    private func performProbeGesture() {
        let kind = ProcessInfo.processInfo.environment["UAPP_OS_AGENT_PROBE_GESTURE"] ?? "swipe"
        NSLog("[UappOsAgent] gesture probe: sending \(kind) (main=\(Thread.isMainThread))")
        if kind == "tap" {
            coordinate(0.5, 0.06).tap()
        } else {
            coordinate(0.5, 0.7).press(forDuration: 0.2, thenDragTo: coordinate(0.5, 0.3))
        }
        NSLog("[UappOsAgent] gesture probe: \(kind) returned")
    }

    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    /// 正規化座標（0〜1）を画面上の座標へ。**解像度に依存しない**ので、
    /// 機種が変わってもホスト側のテストを書き換えずに済む。
    /// **基準を省くと SpringBoard**（iPhone では回転しない＝縦。iPad は未実測）。対照実験（performProbeGesture）はこちらのまま。
    /// アプリを基準にすると、そのアプリの画面（横なら横）で正規化される。
    /// 横画面のアプリは SpringBoard 基準では当たらない（導入先の実機観測。issue #80）。
    /// 「XCUITest がアプリの向きで押す」という機序は推定で、Apple の文書に向きの記述は無い
    private func coordinate(_ x: Double, _ y: Double, on base: XCUIApplication? = nil) -> XCUICoordinate {
        (base ?? springboard).coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    /// `bundleId` の取り出し。**キーが無いときだけ省略扱い**にする
    /// （`null`・数値・空文字を省略扱いにすると、黙って SpringBoard 基準に落ちるため）
    private enum BundleIdParam {
        case absent
        case value(String)
        case invalid(HttpResponse)
    }

    private func bundleIdParam(_ request: HttpRequest) -> BundleIdParam {
        guard let raw = request.json["bundleId"] else { return .absent }
        guard let bundleId = raw as? String else {
            return .invalid(HttpResponse(status: 400, json: ["error": "bundleId は文字列で指定してください"]))
        }
        guard !bundleId.isEmpty else {
            return .invalid(HttpResponse(status: 400, json: ["error": "bundleId が空です"]))
        }
        return .value(bundleId)
    }

    /// 対象アプリが前面でなければ 409 を返す（前面なら nil）。**前面でないアプリを基準にしない**ためのもので、
    /// 前面アプリの上に重なったアラート・通知などを押すことまでは防げない。
    /// 案内は状態で分ける ― 未起動のときに「/activate して」と言うと行き止まりになる（/activate は未起動を拒否する）
    private func notForegroundResponse(_ app: XCUIApplication) -> HttpResponse? {
        let state = app.state
        if state == .runningForeground { return nil }
        let name = UappOsAgent.stateName(state)
        let message: String
        if state == .notRunning || state == .unknown {
            message = "対象アプリが起動していません（state=\(state.rawValue) \(name)）。" +
                      "/activate では起動しません（起動中のアプリを前面へ出すためのもの）"
        } else {
            message = "対象アプリが前面にありません（state=\(state.rawValue) \(name)）。先に /activate してください"
        }
        return HttpResponse(status: 409, json: ["error": message, "state": state.rawValue, "stateName": name])
    }

    // MARK: - issue #85 の補助

    /// `launch` / `terminate` で触ってはいけない bundle id（OS と自分自身）
    private static var protectedBundleIds: Set<String> {
        var ids: Set<String> = ["com.apple.springboard"]
        if let own = Bundle.main.bundleIdentifier { ids.insert(own.lowercased()) }
        return ids
    }

    /// `bundleId` 必須の操作で、アプリを取り出す
    private func requiredApp(_ request: HttpRequest, forLifecycle: Bool = false) -> Result<XCUIApplication, HttpResponse> {
        switch bundleIdParam(request) {
        case .absent:
            return .failure(HttpResponse(status: 400, json: ["error": "bundleId が必要です"]))
        case .invalid(let response):
            return .failure(response)
        case .value(let bundleId):
            // bundle id は Apple 上は大小文字を区別しないので、照合も区別しない（安全側）
            if forLifecycle && UappOsAgent.protectedBundleIds.contains(bundleId.lowercased()) {
                return .failure(HttpResponse(status: 400, json: ["error": "\(bundleId) は起動・終了できません（OS かエージェント自身）"]))
            }
            return .success(XCUIApplication(bundleIdentifier: bundleId))
        }
    }

    /// 要素を探すアプリ（省くと SpringBoard。渡したときは前面でなければ 409）
    private struct ElementBase { let app: XCUIApplication }

    private func elementBase(_ request: HttpRequest) -> Result<ElementBase, HttpResponse> {
        switch bundleIdParam(request) {
        case .absent:
            return .success(ElementBase(app: springboard))
        case .invalid(let response):
            return .failure(response)
        case .value(let bundleId):
            let app = XCUIApplication(bundleIdentifier: bundleId)
            if let response = notForegroundResponse(app) { return .failure(response) }
            return .success(ElementBase(app: app))
        }
    }

    private func baseApp(_ request: HttpRequest) -> XCUIApplication {
        if case .value(let bundleId) = bundleIdParam(request) { return XCUIApplication(bundleIdentifier: bundleId) }
        return springboard
    }

    /// 要素の種類の名前（大小文字を区別）
    private static let elementTypes: [String: XCUIElement.ElementType] = [
        "any": .any, "button": .button, "staticText": .staticText, "textField": .textField,
        "secureTextField": .secureTextField, "textView": .textView, "searchField": .searchField,
        "link": .link, "image": .image, "cell": .cell, "switch": .`switch`, "slider": .slider,
        "alert": .alert, "webView": .webView, "keyboard": .keyboard, "key": .key, "icon": .icon, "other": .other,
    ]

    private static func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        elementTypes.first(where: { $0.value == type })?.key ?? "raw(\(type.rawValue))"
    }

    /// 要素の指定（`/elements` は snapshot を Swift で照合、`/element/*` は述語で引く）
    private struct ElementFilter {
        var identifier: String?
        var label: String?
        var value: String?
        var labelContains: String?
        var type: XCUIElement.ElementType?
    }

    private func elementFilter(_ request: HttpRequest) -> Result<ElementFilter, HttpResponse> {
        var filter = ElementFilter()
        for key in ["identifier", "label", "value", "labelContains", "type"] {
            guard let raw = request.json[key] else { continue }
            guard let text = raw as? String, !text.isEmpty else {
                return .failure(HttpResponse(status: 400, json: ["error": "\(key) は空でない文字列で指定してください"]))
            }
            switch key {
            case "identifier": filter.identifier = text
            case "label": filter.label = text
            case "value": filter.value = text
            case "labelContains": filter.labelContains = text
            default:
                guard let type = UappOsAgent.elementTypes[text] else {
                    return .failure(HttpResponse(status: 400, json: [
                        "error": "type が不正です（大小文字を区別）: \(text)",
                        "allowed": UappOsAgent.elementTypes.keys.sorted()]))
                }
                filter.type = type
            }
        }
        if filter.identifier == nil && filter.label == nil && filter.value == nil && filter.labelContains == nil && filter.type == nil {
            return .failure(HttpResponse(status: 400, json: [
                "error": "identifier / label / value / labelContains / type のどれかが必要です（全要素は /tree）"]))
        }
        return .success(filter)
    }

    private func matches(_ s: XCUIElementSnapshot, _ f: ElementFilter) -> Bool {
        if let t = f.type, t != .any, s.elementType != t { return false }
        if let v = f.identifier, s.identifier != v { return false }
        if let v = f.label, s.label != v { return false }
        if let v = f.value, (s.value as? String) != v { return false }
        if let v = f.labelContains, !s.label.contains(v) { return false }
        return true
    }

    private func collect(_ node: XCUIElementSnapshot, filter: ElementFilter, into out: inout [XCUIElementSnapshot]) {
        if matches(node, filter) { out.append(node) }
        for child in node.children { collect(child, filter: filter, into: &out) }
    }

    private static func describe(_ s: XCUIElementSnapshot, base: CGRect) -> [String: Any] {
        let f = s.frame
        let w = base.width > 0 ? base.width : 1
        let h = base.height > 0 ? base.height : 1
        return [
            "type": elementTypeName(s.elementType),
            "identifier": s.identifier,
            "label": s.label,
            "value": (s.value as? String) ?? NSNull(),
            "placeholder": s.placeholderValue ?? NSNull(),
            "frame": ["x": Double(f.minX), "y": Double(f.minY), "w": Double(f.width), "h": Double(f.height)],
            // そのアプリの画面の正規化座標（/tap に同じ bundleId で渡せる。画面外なら 0〜1 の外）
            "center": ["x": Double((f.midX - base.minX) / w), "y": Double((f.midY - base.minY) / h)],
            "enabled": s.isEnabled,
        ]
    }

    private static func summary(_ e: XCUIElement) -> [String: Any] {
        ["type": elementTypeName(e.elementType), "identifier": e.identifier, "label": e.label]
    }

    /// `/element/*` の要素（**固定の書式に値を引数で渡した述語**で引く。呼び手の文字列を述語にしない）
    private func elementQuery(_ request: HttpRequest) -> Result<XCUIElement, HttpResponse> {
        let base: ElementBase
        switch elementBase(request) {
        case .failure(let response): return .failure(response)
        case .success(let value): base = value
        }
        let filter: ElementFilter
        switch elementFilter(request) {
        case .failure(let response): return .failure(response)
        case .success(let value): filter = value
        }
        var query = base.app.descendants(matching: filter.type ?? .any)
        if let v = filter.identifier { query = query.matching(NSPredicate(format: "identifier == %@", v)) }
        if let v = filter.label { query = query.matching(NSPredicate(format: "label == %@", v)) }
        if let v = filter.value { query = query.matching(NSPredicate(format: "value == %@", v)) }
        if let v = filter.labelContains { query = query.matching(NSPredicate(format: "label CONTAINS %@", v)) }
        let rawIndex = request.jsonDouble("index") ?? 0
        guard rawIndex.isFinite, rawIndex >= 0, rawIndex <= 10_000 else {
            return .failure(HttpResponse(status: 400, json: ["error": "index は 0〜10000 で指定してください"]))
        }
        let index = Int(rawIndex)
        return .success(query.element(boundBy: index))
    }

    /// 要素を引き、現れるまで待つ（現れなければ 404）
    private func resolveElement(_ request: HttpRequest) -> Result<XCUIElement, HttpResponse> {
        switch elementQuery(request) {
        case .failure(let response): return .failure(response)
        case .success(let element):
            let timeout = clampedTimeout(request)
            guard element.waitForExistence(timeout: timeout) else {
                return .failure(HttpResponse(status: 404, json: ["error": "要素が見つかりません（\(timeout) 秒待った）"]))
            }
            return .success(element)
        }
    }

    /// 存在するが押せない要素は押さない（XCUITest に押させるとテストの失敗として記録され、エージェントが止まりうる）。
    /// 画面外ならスクロールしてからやり直す（自動スクロールには任せない）
    private func notHittableResponse(_ element: XCUIElement) -> HttpResponse {
        HttpResponse(status: 409, json: [
            "error": "要素は存在しますが押せません（画面外・他の要素に覆われている等。画面外なら /swipe でスクロールしてからやり直す）",
            "element": UappOsAgent.summary(element)])
    }

    private func clampedTimeout(_ request: HttpRequest) -> Double {
        min(30, max(0, request.jsonDouble("timeout") ?? 5))
    }

    /// キーボードのフォーカスを持つ要素（`hasKeyboardFocus`。公開の属性ではないが、
    /// iOS 18.6 のシミュレータと iOS 16 の実機で使えることを実測した。issue #85）
    private func focusedElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
    }

    /// `/type` を断る理由（送ってよければ nil）。**フォーカスを持つ要素が見えることを必須にする**。
    /// 「キーボードが出ていれば通す」は、Unity の入力欄（シミュレータ）でフォーカスの要素が見えず、
    /// typeText が XCTest の失敗になりエージェントが終了したのでやめた（2026-10-16 に実測）
    private func typeRefusal(in app: XCUIApplication) -> HttpResponse? {
        if focusedElement(in: app).exists { return nil }
        if app.keyboards.firstMatch.exists {
            return HttpResponse(status: 409, json: [
                "error": "キーボードは出ていますが、フォーカスを持つ要素がアクセシビリティに見えません（Unity の入力欄など）。" +
                         "XCUITest の typeText では入力できないので送っていません",
                "keyboardVisible": true])
        }
        return HttpResponse(status: 409, json: [
            "error": "対象アプリにキーボードのフォーカスを持つ要素がありません。先に入力欄を押してください（/tap か /element/tap）",
            "keyboardVisible": false])
    }

    /// 呼び手の数値を Int にする（**非有限・範囲外で Int(Double) が trap してランナーが落ちないように**丸める）
    private static func boundedInt(_ raw: Double?, fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let raw = raw, raw.isFinite else { return fallback }
        return Int(min(Double(range.upperBound), max(Double(range.lowerBound), raw)))
    }

    /// `/orientation` が受け付ける向き。名前は `UIDeviceOrientation` の case 名のまま（Android の番号に揃えない）。
    /// faceUp / faceDown はアプリの画面の向きが変わらない値なので受け付けない
    private static let settableOrientationNames = ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"]
    private static let settableOrientations: [String: UIDeviceOrientation] = [
        "portrait": .portrait,
        "portraitUpsideDown": .portraitUpsideDown,
        "landscapeLeft": .landscapeLeft,
        "landscapeRight": .landscapeRight,
    ]

    /// `UIDeviceOrientation` の名前（受け付けない値も読み直しでは返りうるので全 case を名前にする）
    private static func orientationName(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .unknown: return "unknown"
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        @unknown default: return "other(\(orientation.rawValue))"
        }
    }

    /// `XCUIApplication.State` の名前（rawValue だけだと読み手が対応表を要するため）
    private static func stateName(_ state: XCUIApplication.State) -> String {
        switch state {
        case .unknown: return "unknown"
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "runningBackgroundSuspended"
        case .runningBackground: return "runningBackground"
        case .runningForeground: return "runningForeground"
        @unknown default: return "other(\(state.rawValue))"
        }
    }
}
