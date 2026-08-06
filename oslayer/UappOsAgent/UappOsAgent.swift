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
// ツリーに UI が出ない）。だから要素クエリは提供せず、**座標**で操作する。
// 要素単位の操作はブリッジ側（path・hittable 判定つき）を使うこと。
//
// **接続先の取り違えを防ぐためトークンで認証する**（`UAPP_OS_AGENT_TOKEN`）。
// 並行実行や古いトンネルが同じポートを握っていると、別個体のスクショ・タップへ進んで
// 偽の緑になるため、**トークンが設定されているときは全エンドポイントで一致を要求**し、
// `/status` の `authenticated` で「認証つきの正しい相手か」をホスト側が判定できるようにする。
//
// 提供するコマンド（すべて `X-Uapp-Token` ヘッダが要る。トークン未設定時のみ無認証）:
//   GET  /status                        … 生存確認・画面サイズ・認証状態
//   GET  /screenshot                    … 画面全体の PNG（**OS が合成した結果**）
//   POST /tap      {"x":…,"y":…}        … 正規化座標（0〜1・左上原点）でタップ
//   POST /swipe    {"x1":…,…}           … 正規化座標でスワイプ
//   POST /type     {"bundleId":…,"text":…} … **対象アプリを明示**して文字入力
//   POST /alert    {"button":"…"}       … システムアラートのボタンを押す
//   POST /activate {"bundleId":"…"}     … 実行中のアプリを前面へ（**未起動なら拒否**）
//   POST /stop                          … エージェントを終了
import Foundation
import XCTest

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
                "screen": ["w": Int(frame.width), "h": Int(frame.height)],
            ])

        case ("GET", "/screenshot"):
            // XCUIScreen は**画面の合成結果**を撮る（アプリの描画に限らない）
            let png = XCUIScreen.main.screenshot().pngRepresentation
            return HttpResponse(status: 200, contentType: "image/png", body: png)

        case ("POST", "/tap"):
            guard let x = request.jsonDouble("x"), let y = request.jsonDouble("y") else {
                return HttpResponse(status: 400, json: ["error": "x, y (0..1) が必要です"])
            }
            coordinate(x, y).tap()
            return HttpResponse(status: 200, json: ["ok": true])

        case ("POST", "/swipe"):
            guard let x1 = request.jsonDouble("x1"), let y1 = request.jsonDouble("y1"),
                  let x2 = request.jsonDouble("x2"), let y2 = request.jsonDouble("y2") else {
                return HttpResponse(status: 400, json: ["error": "x1, y1, x2, y2 (0..1) が必要です"])
            }
            let duration = request.jsonDouble("duration") ?? 0.2
            coordinate(x1, y1).press(forDuration: duration, thenDragTo: coordinate(x2, y2))
            return HttpResponse(status: 200, json: ["ok": true])

        case ("POST", "/type"):
            // **対象アプリを明示させる**。`typeText` は「呼び出した要素かその子孫に
            // キーボードフォーカスがあること」が Apple の契約なので、SpringBoard へ
            // 送っても対象アプリの入力欄には入らない（設計を誤っていた箇所）
            guard let text = request.jsonString("text") else {
                return HttpResponse(status: 400, json: ["error": "text が必要です"])
            }
            guard let bundleId = request.jsonString("bundleId") else {
                return HttpResponse(status: 400, json: [
                    "error": "bundleId が必要です（入力欄を持つアプリを明示してください）"])
            }
            let app = XCUIApplication(bundleIdentifier: bundleId)
            guard app.state == .runningForeground else {
                return HttpResponse(status: 409, json: [
                    "error": "対象アプリが前面にありません（state=\(app.state.rawValue)）。先に /activate してください"])
            }
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
            guard let bundleId = request.jsonString("bundleId") else {
                return HttpResponse(status: 400, json: ["error": "bundleId が必要です"])
            }
            let app = XCUIApplication(bundleIdentifier: bundleId)
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

        case ("POST", "/stop"):
            return HttpResponse(status: 200, json: ["ok": true], stopServer: true)

        default:
            return HttpResponse(status: 404, json: ["error": "unknown: \(request.method) \(request.path)"])
        }
    }

    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    /// 正規化座標（0〜1）を画面上の座標へ。**解像度に依存しない**ので、
    /// 機種が変わってもホスト側のテストを書き換えずに済む。
    private func coordinate(_ x: Double, _ y: Double) -> XCUICoordinate {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
}
