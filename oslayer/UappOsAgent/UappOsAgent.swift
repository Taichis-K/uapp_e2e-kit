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
//        **bundleId を省くと SpringBoard の frame（/status の screen）基準**。横向きでは、その大きさが前面によって変わる
//        （アプリが前面なら縦の大きさで、横の画面には当たらない。CC など SpringBoard が前面なら横。issue #94 で実機観測）。
//        渡すとそのアプリの画面基準で押す（横画面のアプリはこちらでないと当たらない。issue #80）。渡したときは前面でなければ 409
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
//        横向きでスナップショットの frame が物理の画面の座標で返る要素は、押す前にアプリの座標へ戻す（issue #94。FrameSpaces）
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
                // **SpringBoard の frame**（bundleId を省いた /tap の正規化の基準）。横向きでは前面によって縦にも横にもなる
                // （アプリが前面なら縦、CC など SpringBoard が前面なら横＝実機観測。issue #94）。横画面のアプリの画面サイズとしては使わない
                "screen": ["w": Int(frame.width), "h": Int(frame.height)],
                // ホストが**押す前に**対応を確かめるための一覧。古いエージェントは bundleId を
                // 黙って無視して SpringBoard 基準で押すので、応答を見てからでは遅い（issue #80）。
                // orientation は一覧として見せるだけ（古い版は /orientation を 404 で返し、何も起きない）
                "features": ["bundleId", "orientation", "app", "elements", "gestures", "press", "openUrl", "typeFocusCheck", "frameSpace"],
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
            // `button` は文字列で、空でないこと（数値などを「指定なし」と読んで先頭＝「許可」を押さない。issue #90）。
            // null とキー無しは「指定なし」
            let rawButton = request.json["button"]
            let wanted: String?
            if rawButton == nil || rawButton is NSNull {
                wanted = nil
            } else if let s = rawButton as? String, !s.isEmpty {
                wanted = s
            } else {
                return HttpResponse(status: 400, json: ["error": "button は空でない文字列で指定してください（省くと先頭のボタン）"])
            }
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: request.jsonDouble("timeout") ?? 5) else {
                return HttpResponse(status: 404, json: ["error": "システムアラートがありません"])
            }
            // 出てくるアニメーションの途中に座標で押すと効かない（tap() は押せる状態を待っていた）ので、ボタンが押せる状態に
            // なるのを待つ（isHittable は一致しなくなっても失敗を記録しない＝実測。2 秒で打ち切り、そのまま進む）
            let readyDeadline = Date().addingTimeInterval(2)
            while !(wanted.map { alert.buttons[$0] } ?? alert.buttons.firstMatch).isHittable && Date() < readyDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            // **アラートを解決し直す読み取りと tap() をしない**（issue #90。#89 と同じ型）。スナップショットを 1 回取り、
            // その子孫のボタンから選んで、中心を SpringBoard の正規化座標で押す（アラートは SpringBoard の木にある）
            let snap: XCUIElementSnapshot
            do { snap = try alert.snapshot() } catch {
                return HttpResponse(status: 404, json: ["error": "システムアラートが閉じた可能性があります（snapshot: \(error)）"])
            }
            var buttons: [XCUIElementSnapshot] = []
            UappOsAgent.collectButtons(snap, into: &buttons)
            let target: XCUIElementSnapshot
            if let label = wanted {
                guard let hit = buttons.first(where: { $0.label == label || $0.identifier == label }) else {
                    return HttpResponse(status: 404, json: [
                        "error": "ボタンがありません: \(label)",
                        "available": buttons.map { $0.label },
                    ])
                }
                target = hit
            } else {
                guard let first = buttons.first else {
                    return HttpResponse(status: 404, json: ["error": "システムアラートにボタンがありません"])
                }
                target = first
            }
            // **横画面では座標で押さない**。SpringBoard の frame は横（例 852×393）で返るのに、アラートのスナップショットの
            // frame は縦の座標のまま（シミュレータ iPhone 16 / iOS 18.6 で実測）で、正規化すると画面の外を指す（#80 と同じ型）。
            // （実機でアプリが前面のときは SpringBoard の frame が縦で返るので、この分岐に入らず座標で押す見込み＝未実測。
            //   縦の座標は物理の画面の座標で、#94 の FrameSpaces で戻せるが、同意の取り違えの危険があるのでここは変えていない）
            // 違うボタンを押すと同意を取り違えるので、横のときは今までどおり要素を引いて tap() する（#89 の型が残る＝残る限界）
            let board = springboard.frame
            if board.width > board.height {
                let button = wanted.map { alert.buttons[$0] } ?? alert.buttons.firstMatch
                button.tap()
                return HttpResponse(status: 200, json: ["ok": true])
            }
            guard !target.frame.isEmpty, let point = normalizedPoint(in: target.frame, rx: 0.5, ry: 0.5, app: springboard),
                  (0...1).contains(point.dx), (0...1).contains(point.dy) else {
                return HttpResponse(status: 409, json: ["error": "ボタンの中心が画面の外です（押していません）: \(target.label)"])
            }
            springboard.coordinate(withNormalizedOffset: point).tap()
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
                // 座標系の判定（issue #94）。既存の frame・center は変えず、frameSpace と appCenter を足す
                // 判定に失敗しても一覧は今までどおり返す（押さない API なので、frameSpace・appCenter を付けないだけ）
                let spaces: FrameSpaces?
                if case .success(let value) = makeFrameSpaces(base.app, root: root, isSpringBoard: !isBundleRequest(request)) {
                    spaces = value
                } else {
                    spaces = nil
                }
                let elements: [[String: Any]] = matched.prefix(limit).map { node in
                    var d = UappOsAgent.describe(node, base: frame)
                    guard let spaces = spaces else { return d }
                    let space = spaces.space(of: node)
                    d["frameSpace"] = space.name
                    if let r = spaces.normalized(node.frame, space) {
                        d["appCenter"] = ["x": Double(r.midX), "y": Double(r.midY)]
                    } else {
                        d["appCenter"] = NSNull()
                    }
                    return d
                }
                return HttpResponse(status: 200, json: ["count": matched.count, "elements": elements])
            }

        case ("POST", "/element/tap"):
            switch resolveElement(request) {
            case .failure(let response): return response
            case .success(let element):
                // **要素を解決し直す読み取り（属性・tap()）をしない**（issue #89）。存在を確かめたあとに要素が述語に
                // 一致しなくなると、その読み取りが XCTest の失敗として記録され、以後の操作が断られてエージェントが終わる。
                // isHittable は一致しなくても記録しない（実測）。属性はこの要求で 1 回だけ取ったスナップショットから読み、
                // 押すのはその frame の中心をアプリの正規化座標で（設計は docs/design/os-agent-element-vanish.md）
                switch pressableSnapshot(element, request: request) {
                case .failure(let response): return response
                case .success(let snap):
                    let app = baseApp(request)
                    // 押す位置はアプリの正規化座標で作る。横向きで物理の画面の座標で返る要素は戻す（issue #94）
                    let spaces: FrameSpaces
                    switch makeFrameSpaces(app, isSpringBoard: !isBundleRequest(request)) {
                    case .failure(let response): return response
                    case .success(let value): spaces = value
                    }
                    let space = spaces.space(of: snap)
                    guard let rect = spaces.normalized(snap.frame, space) else { return frameSpaceUnknownResponse(snap, spaces: spaces) }
                    let point: CGPoint
                    switch pressTarget(rect, snap: snap, space: space, spaces: spaces, app: app) {
                    case .failure(let response): return response
                    case .success(let value): point = value
                    }
                    pressAt(point, app: app)
                    return HttpResponse(status: 200, json: ["ok": true, "element": UappOsAgent.summary(snap)])
                }
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
                // /element/tap と同じく、要素を解決し直す読み取りと操作をしない（issue #89）
                let snap: XCUIElementSnapshot
                switch pressableSnapshot(element, request: request) {
                case .failure(let response): return response
                case .success(let value): snap = value
                }
                let app = baseApp(request)
                // 比べる枠と押す位置は、すべてアプリの正規化座標にそろえる（issue #94。生の frame どうしを比べない）。
                // 判定は押す前の根の写しで作る（押したあとに Window の構成が変わると追えない＝設計書の残る限界）
                let spaces: FrameSpaces
                switch makeFrameSpaces(app, isSpringBoard: !isBundleRequest(request)) {
                case .failure(let response): return response
                case .success(let value): spaces = value
                }
                let space = spaces.space(of: snap)
                guard let target = spaces.normalized(snap.frame, space) else { return frameSpaceUnknownResponse(snap, spaces: spaces) }
                let point: CGPoint
                switch pressTarget(target, snap: snap, space: space, spaces: spaces, app: app) {
                case .failure(let response): return response
                case .success(let value): point = value
                }
                let summary = UappOsAgent.summary(snap)
                // フォーカスの要素の座標系。根の写しで見つからなければ対象と同じと見なす
                func normFocus(_ s: XCUIElementSnapshot) -> CGRect? {
                    let fs = spaces.space(of: s)
                    return spaces.normalized(s.frame, (fs == .unknown || fs == .unmeasured) ? space : fs)
                }
                pressAt(point, app: app)
                // **押した要素（かその子）にフォーカスが来たかを確かめ、フォーカスを持つ要素へ入力する**。
                // 「アプリのどこかにフォーカスがある」だけだと、別の入力欄がフォーカスを持ったまま押しても移らない要素を
                // 指定したときに、typeText が XCTest の失敗になりエージェントが止まりうる（#81 と同じ型）。
                // フォーカスの要素も exists（記録しない）のあとスナップショットで読む（issue #89）。
                // 「来た」と見なす枠は 3 つ（issue #93。入力欄はキーボードを避けて動くことがある）:
                //   1. 押す前の frame  2. 最初に来たと判定したときのフォーカスの frame（clear で値が変わり、述語に一致しなくなっても読み直せるように）
                //   3. 対象の今の frame（exists → try? snapshot() で読み直す。読めない・幅か高さが 0 なら使わない）
                var focusedFrame: CGRect? = nil
                func focusedInTarget() -> XCUIElementSnapshot? {
                    let focused = focusedElement(in: app)
                    guard focused.exists, let s = try? focused.snapshot(), let sRect = normFocus(s) else { return nil }
                    var frames = [target]
                    if let f = focusedFrame { frames.append(f) }
                    if element.exists, let now = try? element.snapshot(), now.frame.width > 0, now.frame.height > 0,
                       let nowRect = spaces.normalized(now.frame, space) {
                        frames.append(nowRect)
                    }
                    // 1 pt の許容を正規化座標に直す
                    guard frames.contains(where: { $0.insetBy(dx: -spaces.tolX, dy: -spaces.tolY).contains(sRect) }) else { return nil }
                    return s
                }
                let deadline = Date().addingTimeInterval(2)
                var field = focusedInTarget()
                while field == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.1); field = focusedInTarget() }
                guard let input = field else {
                    return HttpResponse(status: 409, json: ["error": "要素を押しましたが、その要素にキーボードのフォーカスが来ません", "element": summary])
                }
                focusedFrame = normFocus(input)
                if clear {
                    let placeholder = input.placeholderValue ?? ""
                    let current = (input.value as? String) ?? ""
                    // **値がプレースホルダーと同じでも消す**（同じ文字列の実際の値かもしれない。空欄に削除キーを送っても害は無い）
                    if !current.isEmpty {
                        // 右端寄りを押してカーソルを末尾へ寄せてから、値の長さぶん削除キーを送る
                        // （要素を基準にした座標は解決し直すので、アプリの座標で押す。入力はフォーカスへ届くアプリへ送る）
                        // （キーボードの検査はしない。押す点は画面との共通部分（見えている部分）に切ってから作る＝issue #94 の追補）
                        // 判定のあとに欄がさらに動くことがある（キーボードを避ける途中で判定した等。issue #93）ので、
                        // 押す直前にフォーカスの要素を読み直し、その frame を押す（読めなければ判定したときの frame）
                        let fresh = focusedInTarget() ?? input
                        // normFocus は対象の座標系（決まっている）へ戻すので nil にならない。なった場合も、対象は押したあと
                        guard let freshRect = normFocus(fresh) else {
                            return HttpResponse(status: 409, json: [
                                "error": "フォーカスの要素の座標を作れません（対象は押しました。既存の値は消していません。入力していません）",
                                "remaining": NSNull()])
                        }
                        focusedFrame = freshRect
                        let visible = freshRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                        guard !visible.isNull, visible.width * spaces.base.width >= UappOsAgent.minVisiblePt,
                              visible.height * spaces.base.height >= UappOsAgent.minVisiblePt else {
                            return HttpResponse(status: 409, json: [
                                "error": "入力欄の見えている部分が小さすぎて、末尾を押せません（対象は押しました。既存の値は消していません。入力していません）",
                                "remaining": NSNull()])
                        }
                        pressNormalized(visible, rx: 0.95, ry: 0.5, app: app)
                        // 押したことでフォーカスが外れていたら削除キーを送らない（フォーカスが無いまま typeText を呼ぶと
                        // XCTest の失敗になりエージェントが止まる＝#81 の型）
                        guard focusedInTarget() != nil else {
                            return HttpResponse(status: 409, json: [
                                "error": "既存の値を消す前に入力欄のフォーカスが外れました。入力していません",
                                "remaining": NSNull()])
                        }
                        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4))
                    }
                    // **消えたか読み直す**。残っていれば入力しない（黙って混ざった値を入れない）。
                    // 読み直せない（フォーカスが外れた・対象の外へ移った）ときも、消えたか分からないので入力しない
                    guard let again = focusedInTarget() else {
                        return HttpResponse(status: 409, json: [
                            "error": "既存の値を消したあとに入力欄を読み直せません（フォーカスが外れた可能性）。入力していません",
                            "remaining": NSNull()])
                    }
                    let after = (again.value as? String) ?? ""
                    // **消したあとの値がプレースホルダーと同じなら、消す前の値にかかわらず判別できない**
                    // （空欄なのか、部分的に消えた残りがたまたまプレースホルダーと同じ文字列なのか。例: "prefixguest" → "guest"）
                    if !placeholder.isEmpty && after == placeholder {
                        return HttpResponse(status: 409, json: [
                            "error": "値がプレースホルダーと同じで、空欄か既存の値かを判別できません。入力していません（空欄なら clear を付けずに入れる）",
                            "remaining": after])
                    }
                    guard after.isEmpty else {
                        return HttpResponse(status: 409, json: [
                            "error": "既存の値を消し切れませんでした（カーソル位置・消去ボタン・伏せ字の可能性）。入力していません",
                            "remaining": after])
                    }
                }
                app.typeText(text)
                // 入力で要素が消えることがある（確定で画面が移る等）ので、対象の中のフォーカスの要素があるときだけ読む
                let value: Any = (focusedInTarget()?.value as? String) ?? NSNull()
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
            // **開けないと決まっているスキームは渡す前に弾く**（issue #92）。XCUITest は開けない URL を
            // 「Failed to open the default app for a URL」の失敗として記録し、以後の操作が断られてエージェントが終わる
            // （200 を返したあとで）。実測で終わったのは data / javascript / about / file。blob は推測。
            // 対応するアプリの無い独自スキーム・標準のスキームは事前に見分けられないので弾けない（残る限界）。
            // URL のスキームは大小文字を区別しない
            if UappOsAgent.unopenableSchemes.contains(scheme.lowercased()) {
                return HttpResponse(status: 400, json: [
                    "error": "このスキームの URL はほかのアプリでは開けません（\(scheme):）。渡すとエージェントが終わるので開いていません"])
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
    /// **基準を省くと SpringBoard**（その frame が基準。横向きでは前面によって縦にも横にもなる＝実機観測。issue #94。iPad は未実測）。
    /// 対照実験（performProbeGesture）はこちらのまま。
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

    /// bundleId を渡した要求か（/element/* の基準がアプリか SpringBoard か）
    private func isBundleRequest(_ request: HttpRequest) -> Bool {
        if case .value = bundleIdParam(request) { return true }
        return false
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

    /// 要素の要約。**スナップショットから読む**（`XCUIElement` の属性を読むと要素を解決し直し、一致しなくなっていると
    /// XCTest の失敗が記録されてエージェントが終わる。issue #89）
    private static func summary(_ s: XCUIElementSnapshot) -> [String: Any] {
        ["type": elementTypeName(s.elementType), "identifier": s.identifier, "label": s.label]
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
    private func notHittableResponse(_ snap: XCUIElementSnapshot) -> HttpResponse {
        HttpResponse(status: 409, json: [
            "error": "要素は存在しますが押せません（画面外・他の要素に覆われている等。画面外なら /swipe でスクロールしてからやり直す）",
            "element": UappOsAgent.summary(snap)])
    }

    /// 押す前の要素を、`isHittable`（一致しなくても記録しない）と 1 回だけのスナップショットで確かめる（issue #89）。
    /// スナップショットが取れない（確かめたあとに一致しなくなった可能性）ときは、押す経路なら 404、押せない経路なら 409 のまま `element` を外す
    private func pressableSnapshot(_ element: XCUIElement, request: HttpRequest) -> Result<XCUIElementSnapshot, HttpResponse> {
        let hittable = element.isHittable
        let snap: XCUIElementSnapshot
        do { snap = try element.snapshot() } catch {
            // 404 の本文は "unknown:" で始めない（ドライバはそれを「古いエージェント」と読む）
            let why = "要素は確かめたあとに一致しなくなった可能性があります（snapshot: \(error)）"
            return .failure(hittable
                ? HttpResponse(status: 404, json: ["error": why])
                : HttpResponse(status: 409, json: ["error": "要素は存在しますが押せません。" + why]))
        }
        guard hittable else { return .failure(notHittableResponse(snap)) }
        return .success(snap)
    }

    /// 押す点を決める（押さないなら応答を返す）。中心が画面の中ならその中心。
    /// **中心が画面の外でも、見えている部分（画面と祖先の frame との共通部分）が幅・高さとも 10 pt 以上なら、その中心**
    /// （iPhone 8 の横の CC で、右端で半分見えているボタンを押すため。issue #94 の追補）。要素が画面より大きい次元を持つ・
    /// 祖先が決まらない・見えている部分が小さいときは 409。
    /// **要素がキーボードの裏にある**（中心がキーボードの中で、要素がキーボードの一部でない）なら 409
    /// （中心を押すとキーを押して文字が入る）。キー・Return・完了などキーボードの一部は押す。
    /// 「丸ごと入っていればキーボードの一部」とは見なさない（キーボードの裏に丸ごと隠れた要素を押してしまう＝実測）
    /// `rect` は対象の frame をアプリの正規化座標にしたもの（`FrameSpaces.normalized`）。キーボードも同じ座標にそろえて比べる（issue #94）。
    /// キーボードの座標系は根の写しで探し、見つからなければ対象と同じ（`space`）と見なす
    private func pressTarget(_ rect: CGRect, snap: XCUIElementSnapshot, space: FrameSpace, spaces: FrameSpaces,
                             app: XCUIApplication) -> Result<CGPoint, HttpResponse> {
        var center = CGPoint(x: rect.midX, y: rect.midY)
        if !((0...1).contains(center.x) && (0...1).contains(center.y)) {
            switch visibleCenter(rect, snap: snap, space: space, spaces: spaces, app: app) {
            case .failure(let why):
                return .failure(HttpResponse(status: 409, json: [
                    "error": "要素の中心が画面の外です（\(why)。/swipe でスクロールしてからやり直す）"]))
            case .success(let p): center = p
            }
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, let kb = try? keyboard.snapshot() {
            // キーボードの座標系が根の写しで決まらなければ（unknown）、戻す対応があるならアプリ・物理の画面の両方の解釈で比べ、
            // どちらかで裏なら止める（安全側）。未実測の区域（unmeasured）は戻す式が無いので、アプリの座標として比べる
            let found = spaces.space(of: kb)
            let candidates: [FrameSpace]
            switch found {
            case .unknown: candidates = spaces.canConvert ? [.app, .screen] : [.app]
            case .unmeasured: candidates = [.app]
            default: candidates = [found]
            }
            for ks in candidates {
                if let kbRect = spaces.normalized(kb.frame, ks), kbRect.contains(center),
                   !UappOsAgent.hasDescendant(kb, rect: rect, space: ks, spaces: spaces) {
                    return .failure(HttpResponse(status: 409, json: [
                        "error": "要素の押す点がキーボードの裏にあります（押すとキーを押します）。キーボードを閉じるかスクロールしてからやり直す"]))
                }
            }
        }
        return .success(center)
    }

    /// 見えている部分の下限（pt）。端の切れ端を押さないため（issue #94 の追補。根拠は iPhone 8 の CC の幅 32 pt の 1 例）
    static let minVisiblePt: CGFloat = 10

    /// 中心が画面の外の要素の、見えている部分の中心（アプリの正規化座標）。失敗の理由を文字列で返す
    private func visibleCenter(_ rect: CGRect, snap: XCUIElementSnapshot, space: FrameSpace, spaces: FrameSpaces,
                               app: XCUIApplication) -> Result<CGPoint, VisibleError> {
        // 画面より大きい次元を持つ要素は、見えている部分の真ん中が別の子要素に当たりうるので押さない
        guard rect.width <= 1, rect.height <= 1 else { return .failure(VisibleError("要素が画面より大きい")) }
        // 祖先（スクロールビューなど）に切り取られた部分を外すため、根を取り直して祖先をたどる（この経路だけの追加の取得）
        guard let root = try? app.snapshot() else { return .failure(VisibleError("根のスナップショットを取れない")) }
        var paths: [[XCUIElementSnapshot]] = []
        func find(_ n: XCUIElementSnapshot, _ path: [XCUIElementSnapshot]) {
            let g = n.frame, f = snap.frame
            if n.elementType == snap.elementType && n.identifier == snap.identifier && n.label == snap.label &&
                abs(g.minX - f.minX) <= 1 && abs(g.minY - f.minY) <= 1 && abs(g.maxX - f.maxX) <= 1 && abs(g.maxY - f.maxY) <= 1 {
                paths.append(path)
            }
            for c in n.children { find(c, path + [n]) }
        }
        find(root, [])
        guard paths.count == 1 else { return .failure(VisibleError("祖先を決められない（一致 \(paths.count) 件）")) }
        var visible = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        for ancestor in paths[0].dropFirst() {   // 根（アプリ）は除く
            guard let a = spaces.normalized(ancestor.frame, space), a.width > 0, a.height > 0 else { continue }
            visible = visible.intersection(a)
            if visible.isNull { break }
        }
        guard !visible.isNull, visible.width * spaces.base.width >= UappOsAgent.minVisiblePt,
              visible.height * spaces.base.height >= UappOsAgent.minVisiblePt else {
            return .failure(VisibleError("見えている部分が \(Int(UappOsAgent.minVisiblePt)) pt より小さいか無い"))
        }
        return .success(CGPoint(x: visible.midX, y: visible.midY))
    }

    struct VisibleError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// アプリの正規化座標の点を押す（要素を解決し直さない）
    private func pressAt(_ p: CGPoint, app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: p.x, dy: p.y)).tap()
    }

    /// 正規化した矩形の中の点（幅・高さに対する割合）を、アプリの正規化座標で押す（要素を解決し直さない）
    private func pressNormalized(_ rect: CGRect, rx: CGFloat, ry: CGFloat, app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: rect.minX + rect.width * rx, dy: rect.minY + rect.height * ry)).tap()
    }

    private func frameSpaceUnknownResponse(_ snap: XCUIElementSnapshot, spaces: FrameSpaces) -> HttpResponse {
        let space = spaces.space(of: snap)
        let why = space == .unmeasured
            ? "要素は、座標系を確かめていない区域（縦長の基準の下で、物理の画面を横にした大きさの Window）にあります"
            : "根のスナップショットで同じ要素が見つからなかったか、座標系の違う複数の要素に一致しました（件数は matches）"
        return HttpResponse(status: 409, json: [
            "error": "要素の座標系を決められません。押していません。" + why,
            "reason": space == .unmeasured ? "frameSpaceUnmeasured" : "frameSpaceUnknown",
            "matches": spaces.matchCount(of: snap),
            "orientation": UappOsAgent.orientationName(XCUIDevice.shared.orientation),
            "element": UappOsAgent.summary(snap)])
    }

    /// 要素の frame の座標系（issue #94。設計は docs/design/os-agent-landscape-element-frame.md）
    enum FrameSpace {
        /// app: アプリの座標 / screen: 物理の画面の座標 / unknown: 根の写しで決まらない /
        /// unmeasured: 縦長の基準の下で形が入れ替わった、物理の画面の大きさの Window の下（座標系が未実測。戻さない）
        case app, screen, unknown, unmeasured
        var name: String {
            switch self { case .app: return "app"; case .screen: return "screen"; case .unknown: return "unknown"; case .unmeasured: return "unmeasured" }
        }
    }

    /// 要求ごとに 1 回作る、座標系の判定と変換。
    /// 横長の基準の下に「形が入れ替わり、大きさが物理の画面（screenPoint が張る矩形）と一致する Window」があれば、
    /// その下の要素のスナップショットの frame は物理の画面の座標（シミュレータの ATT・実機の CC で実測）。それ以外はアプリの座標
    struct FrameSpaces {
        let base: CGRect
        /// 根の写しのノードと、その座標系。nil なら判定しない（すべてアプリの座標）
        let nodes: [(node: XCUIElementSnapshot, space: FrameSpace)]?
        /// 物理の点 → アプリの正規化座標（p00 と、p10 − p00・p01 − p00）
        let p00: CGPoint, a: CGVector, b: CGVector

        var tolX: CGFloat { 1 / base.width }
        /// 物理の画面の座標を戻す対応を持っているか（基準が横長で、物理の画面の Window があったとき）
        var canConvert: Bool { nodes?.contains(where: { $0.space == .screen }) ?? false }
        var tolY: CGFloat { 1 / base.height }

        func space(of s: XCUIElementSnapshot) -> FrameSpace { lookup(s).space }

        /// 根の写しでの一致の件数（同一のオブジェクトなら 1）
        func matchCount(of s: XCUIElementSnapshot) -> Int { lookup(s).count }

        private func lookup(_ s: XCUIElementSnapshot) -> (space: FrameSpace, count: Int) {
            guard let nodes = nodes else { return (.app, 0) }
            // 同じ根の写しから取ったノードは同一のオブジェクト（/elements）。別のスナップショットなら属性で照合する
            if let hit = nodes.first(where: { ($0.node as AnyObject) === (s as AnyObject) }) { return (hit.space, 1) }
            let f = s.frame
            let same = nodes.filter { n in
                let g = n.node.frame
                return n.node.elementType == s.elementType && n.node.identifier == s.identifier && n.node.label == s.label &&
                    abs(g.minX - f.minX) <= 1 && abs(g.minY - f.minY) <= 1 && abs(g.maxX - f.maxX) <= 1 && abs(g.maxY - f.maxY) <= 1
            }
            guard let first = same.first?.space else { return (.unknown, 0) }
            return (same.allSatisfy({ $0.space == first }) ? first : .unknown, same.count)
        }

        /// frame をアプリの正規化座標の矩形にする（unknown なら nil）
        func normalized(_ f: CGRect, _ space: FrameSpace) -> CGRect? {
            switch space {
            case .unknown, .unmeasured: return nil
            case .app:
                return CGRect(x: (f.minX - base.minX) / base.width, y: (f.minY - base.minY) / base.height,
                              width: f.width / base.width, height: f.height / base.height)
            case .screen:
                let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
                               CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)].map(toApp)
                let xs = corners.map { $0.x }, ys = corners.map { $0.y }
                return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
        }

        /// 物理の点 s を s = p00 + u·a + v·b の (u, v) へ
        func toApp(_ s: CGPoint) -> CGPoint {
            let dx = s.x - p00.x, dy = s.y - p00.y
            let det = a.dx * b.dy - a.dy * b.dx
            return CGPoint(x: (dx * b.dy - dy * b.dx) / det, y: (a.dx * dy - a.dy * dx) / det)
        }
    }

    /// `FrameSpaces` を作る。基準の frame が縦長なら判定しない（iPhone の物理の画面は縦なので入れ替わりは起きない）。
    /// `root` を渡せばそれを使う（/elements は既に取っている）
    private func makeFrameSpaces(_ app: XCUIApplication, root given: XCUIElementSnapshot? = nil,
                                 isSpringBoard: Bool = true) -> Result<FrameSpaces, HttpResponse> {
        // /elements は根の frame を基準にする（今までの center と同じ。アプリを解決し直す読み取りを増やさない）
        let base = given?.frame ?? app.frame
        guard base.width > 0, base.height > 0 else { return .failure(UappOsAgent.cannotPressResponse) }
        let plain = FrameSpaces(base: base, nodes: nil, p00: .zero, a: CGVector(dx: 1, dy: 0), b: CGVector(dx: 0, dy: 1))
        let wide = base.width > base.height
        // 縦長の基準は、端末が縦なら見ない（毎回の根の取得を避ける）。縦以外の向き（横・faceUp など）なら、
        // 形が入れ替わった Window の下を「決められない」にする（実機でアプリが前面・横のとき SpringBoard の frame は縦で、
        // Window は横＝その下の要素の座標系は未実測。戻す式を確かめていないので押さない）
        if !wide && XCUIDevice.shared.orientation == .portrait { return .success(plain) }
        let root: XCUIElementSnapshot
        if let given = given { root = given } else {
            do { root = try app.snapshot() } catch {
                // bundleId のアプリの要素はアプリの座標で返る（実測）ので、取れなければ今までと同じ計算にする（今当たっているものを壊さない）。
                // 縦長の基準の確かめは安全側に寄せるための追加なので、取れなければ今までと同じ計算に戻す
                if !isSpringBoard || !wide { return .success(plain) }
                return .failure(HttpResponse(status: 409, json: [
                    "error": "根のスナップショットを取れません（\(error)）。押していません", "reason": "snapshotFailed"]))
            }
        }
        let rootWide = root.frame.width > root.frame.height
        var windows: [XCUIElementSnapshot] = []
        func findWindows(_ n: XCUIElementSnapshot) {
            if n.elementType == .window && (n.frame.width > n.frame.height) != rootWide { windows.append(n) }
            for c in n.children { findWindows(c) }
        }
        findWindows(root)
        guard !windows.isEmpty else { return .success(plain) }
        if !wide {
            // 物理の画面（= 縦長の基準）を横にした大きさの Window だけを区域にする（小さな横長の Window は対象にしない）
            let zones = windows.filter { w in
                abs(w.frame.minX) <= 1 && abs(w.frame.minY) <= 1 &&
                    abs(w.frame.width - base.height) <= 1 && abs(w.frame.height - base.width) <= 1
            }
            guard !zones.isEmpty else { return .success(plain) }
            return .success(FrameSpaces(base: base, nodes: UappOsAgent.markNodes(root, zones: zones, as: .unmeasured),
                                        p00: .zero, a: CGVector(dx: 1, dy: 0), b: CGVector(dx: 0, dy: 1)))
        }
        // 物理の画面の対応を XCTest に聞く（アプリの解決は要るが、要素の解決は要らない）
        guard app.exists else {
            return .failure(HttpResponse(status: 404, json: ["error": "アプリが終わりました（押していません）"]))
        }
        let p00 = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).screenPoint
        let p10 = app.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0)).screenPoint
        let p01 = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).screenPoint
        let a = CGVector(dx: p10.x - p00.x, dy: p10.y - p00.y), b = CGVector(dx: p01.x - p00.x, dy: p01.y - p00.y)
        guard abs(a.dx * b.dy - a.dy * b.dx) > 0.5 else { return .failure(UappOsAgent.cannotPressResponse) }
        let p11 = CGPoint(x: p10.x + b.dx, y: p10.y + b.dy)
        let xs = [p00.x, p10.x, p01.x, p11.x], ys = [p00.y, p10.y, p01.y, p11.y]
        let physW = xs.max()! - xs.min()!, physH = ys.max()! - ys.min()!
        let onScreen = windows.filter { w in
            abs(w.frame.minX) <= 1 && abs(w.frame.minY) <= 1 && abs(w.frame.width - physW) <= 1 && abs(w.frame.height - physH) <= 1
        }
        guard !onScreen.isEmpty else { return .success(plain) }
        return .success(FrameSpaces(base: base, nodes: UappOsAgent.markNodes(root, zones: onScreen, as: .screen), p00: p00, a: a, b: b))
    }

    /// 根の写しの全ノードに座標系の印を付ける（`zones` の Window の下は `space`、それ以外は app）
    private static func markNodes(_ root: XCUIElementSnapshot, zones: [XCUIElementSnapshot],
                                  as space: FrameSpace) -> [(node: XCUIElementSnapshot, space: FrameSpace)] {
        var nodes: [(node: XCUIElementSnapshot, space: FrameSpace)] = []
        func walk(_ n: XCUIElementSnapshot, _ under: Bool) {
            let here = under || zones.contains(where: { ($0 as AnyObject) === (n as AnyObject) })
            nodes.append((n, here ? space : .app))
            for c in n.children { walk(c, here) }
        }
        walk(root, false)
        return nodes
    }

    /// スナップショットの子孫のうち、種類がボタンのもの（木の順）
    private static func collectButtons(_ node: XCUIElementSnapshot, into out: inout [XCUIElementSnapshot]) {
        for child in node.children {
            if child.elementType == .button { out.append(child) }
            collectButtons(child, into: &out)
        }
    }

    /// スナップショットの子孫に、同じ矩形（アプリの正規化座標。各辺 1 pt の許容）の要素があるか。子孫は `space` で正規化する
    private static func hasDescendant(_ node: XCUIElementSnapshot, rect: CGRect, space: FrameSpace, spaces: FrameSpaces) -> Bool {
        for child in node.children {
            if let f = spaces.normalized(child.frame, space),
               abs(f.minX - rect.minX) <= spaces.tolX && abs(f.minY - rect.minY) <= spaces.tolY &&
               abs(f.maxX - rect.maxX) <= spaces.tolX && abs(f.maxY - rect.maxY) <= spaces.tolY { return true }
            if hasDescendant(child, rect: rect, space: space, spaces: spaces) { return true }
        }
        return false
    }

    /// `frame` の中の点（幅・高さに対する割合）を、アプリの正規化座標にする（基準はアプリの `frame`）
    private func normalizedPoint(in frame: CGRect, rx: CGFloat, ry: CGFloat, app: XCUIApplication) -> CGVector? {
        let base = app.frame
        guard base.width > 0, base.height > 0 else { return nil }
        return CGVector(dx: (frame.minX + frame.width * rx - base.minX) / base.width,
                        dy: (frame.minY + frame.height * ry - base.minY) / base.height)
    }


    private static var cannotPressResponse: HttpResponse {
        HttpResponse(status: 409, json: ["error": "押す座標を作れません（アプリの frame の幅か高さが 0）。押していません"])
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

    /// `/open-url` が渡す前に弾くスキーム（小文字。issue #92）
    private static let unopenableSchemes: Set<String> = ["data", "javascript", "about", "file", "blob"]

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
