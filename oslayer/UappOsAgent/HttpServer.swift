// XCUITest プロセス内で動かす最小 HTTP サーバー。
//
// **外部ライブラリを足さない**ためだけの実装（このキットの絶対条件が「完全無料・OSS のみ」で、
// 依存を増やさないほど導入先の負担が減る）。用途は uapp_e2e のエージェント専用なので、
// **同時 1 接続・Content-Length ありの単純なリクエストだけ**を扱う割り切った作り。
//
// **ループバックにだけ bind する**（127.0.0.1）。実機ではホストから `iproxy` の USB トンネル
// 経由で届くので外部公開は不要で、公開すると同じ LAN の他マシンから操作できてしまう。
// ただし**ループバックは LAN から隔離するだけで認証ではない** — 同じマシンの別プロセス・
// 別ユーザーからは届くので、トークン（`X-Uapp-Token`）で認証する。
//
// **不正な入力で落ちないこと**を優先する（エージェントが死ぬとテスト全体が止まる）:
// 負や巨大な Content-Length、終端の来ないヘッダ、放置された接続はすべて打ち切る。
import Foundation
import Network

struct HttpRequest {
    let method: String
    let path: String
    let json: [String: Any]

    func jsonString(_ key: String) -> String? { json[key] as? String }
    func jsonDouble(_ key: String) -> Double? {
        if let d = json[key] as? Double { return d }
        if let i = json[key] as? Int { return Double(i) }
        return nil
    }
}

struct HttpResponse {
    let status: Int
    var contentType: String = "application/json; charset=utf-8"
    var body: Data = Data()
    var stopServer: Bool = false

    init(status: Int, contentType: String = "application/json; charset=utf-8",
         body: Data = Data(), stopServer: Bool = false) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.stopServer = stopServer
    }

    init(status: Int, json: [String: Any], stopServer: Bool = false) {
        self.init(status: status,
                  body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(),
                  stopServer: stopServer)
    }
}

final class HttpServer {
    /// 受け付ける上限（**攻撃ではなく事故で落ちないため**の常識的な上限）
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 4 * 1024 * 1024
    /// **リクエストを受け取り終えるまでの期限**。ハンドラの実行時間は縛らない
    /// （XCUITest の操作は swipe の duration やアラート待ちで 30 秒を超えうるので、
    /// 一律に接続を切ると「クライアントは失敗したのに画面は変わっている」状態になる）
    private static let receiveTimeoutSec = 30.0

    var handler: ((HttpRequest) -> HttpResponse)?
    private(set) var shouldStop = false

    private let port: UInt16
    private let token: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "uapp.os.agent.http")

    init(port: UInt16, token: String? = nil) {
        self.port = port
        self.token = token
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // **ループバック限定**
        // **ポート再利用は許可しない** — 許すと、古いエージェントが残っている状態でも
        // 起動できてしまい、ホストがどちらへ繋いだのか分からなくなる（偽の緑の温床）
        params.allowLocalEndpointReuse = false
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // **放置された接続を残さない**（応答を待たない相手がいるとスロットが埋まる）。
        // ただし**リクエストを受け取り終えたら解除する** — 解除しないと、長い XCUITest 操作の
        // 最中や完了直後にこのタイマーが応答をキャンセルしてしまう
        let received = ReceiveState()
        queue.asyncAfter(deadline: .now() + Self.receiveTimeoutSec) { [weak connection] in
            if !received.done { connection?.cancel() }
        }
        receive(connection, buffer: Data(), received: received)
    }

    /// 受信完了を伝えるだけの入れ物（同じ直列キュー上でしか触らないので排他は不要）
    private final class ReceiveState { var done = false }

    /// **ヘッダが揃い、Content-Length ぶんの本文が来るまで読み続ける**
    /// （一度の receive で全部届く保証は無い。ここを省くと大きな POST が壊れる）
    private func receive(_ connection: NWConnection, buffer: Data, received: ReceiveState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if error != nil { connection.cancel(); return }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                // ヘッダ終端が来ないまま膨らむ入力は打ち切る
                if isComplete || buffer.count > Self.maxHeaderBytes { connection.cancel() }
                else { self.receive(connection, buffer: buffer, received: received) }
                return
            }
            let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
            let header = String(decoding: headerData, as: UTF8.self)
            // **負値・巨大値をそのまま信じない**（負だと Data の range が反転してクラッシュする）
            guard let contentLength = Self.contentLength(in: header),
                  contentLength >= 0, contentLength <= Self.maxBodyBytes else {
                self.send(HttpResponse(status: 400, json: ["error": "invalid Content-Length"]), on: connection)
                return
            }
            let bodyStart = headerEnd.upperBound
            let bodyBytes = buffer.count - (bodyStart - buffer.startIndex)
            if bodyBytes < contentLength {
                if isComplete { connection.cancel() } else { self.receive(connection, buffer: buffer, received: received) }
                return
            }

            let body = buffer[bodyStart..<(bodyStart + contentLength)]
            // **ここから先はハンドラの実行時間**。受信は終わったので打ち切りタイマーを無効化する
            received.done = true
            let response = self.respond(header: header, body: Data(body))
            self.send(response, on: connection)
        }
    }

    private func respond(header: String, body: Data) -> HttpResponse {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return HttpResponse(status: 400, json: ["error": "bad request line"]) }
        // **トークンが設定されているなら全エンドポイントで一致を要求する**
        // （ループバックは同一マシンの他プロセスからは届くため、これが唯一の識別子）
        if let token = token, Self.headerValue("x-uapp-token", in: header) != token {
            return HttpResponse(status: 401, json: ["error": "invalid or missing X-Uapp-Token"])
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let request = HttpRequest(method: parts[0], path: parts[1], json: json)

        // **コマンドはメインスレッドで実行する**（XCUITest の API はメインスレッド前提）
        var response = HttpResponse(status: 500, json: ["error": "no handler"])
        if let handler = handler {
            if Thread.isMainThread {
                response = handler(request)
            } else {
                DispatchQueue.main.sync { response = handler(request) }
            }
        }
        if response.stopServer { shouldStop = true }
        return response
    }

    private func send(_ response: HttpResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Content-Length。ヘッダが無ければ 0、**壊れていれば nil**（呼び出し側が 400 で返す）。
    private static func contentLength(in header: String) -> Int? {
        guard let raw = headerValue("content-length", in: header) else { return 0 }
        return Int(raw)
    }

    private static func headerValue(_ name: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
