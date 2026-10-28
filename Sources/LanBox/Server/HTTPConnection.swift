import Foundation
import Network

/// 一个 TCP 连接只处理一个请求（Connection: close），这样流式上传、下载和 SSE 都很直接。
final class HTTPConnection: @unchecked Sendable {
    let id = UUID()
    let queue: DispatchQueue
    let remoteIP: String
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false
    private var closeHandlers: [() -> Void] = []
    var onRequest: ((HTTPRequest, HTTPConnection) -> Void)?
    var onClose: ((HTTPConnection) -> Void)?

    static let chunkSize = 512 * 1024

    init(_ connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "lanbox.conn")
        if case let .hostPort(host, _) = connection.endpoint {
            var ip = "\(host)"
            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
            if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }
            remoteIP = ip
        } else {
            remoteIP = "未知"
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        readHead()
    }

    // MARK: Reading

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer[..<end.lowerBound]
                self.buffer = Data(self.buffer[end.upperBound...])
                guard let request = HTTPRequest.parse(Data(head)) else {
                    self.respond(HTTPHead(400), body: Data())
                    return
                }
                self.onRequest?(request, self)
            } else if self.buffer.count > 64 * 1024 {
                self.respond(HTTPHead(431), body: Data())
            } else if complete || error != nil {
                self.close()
            } else {
                self.readHead()
            }
        }
    }

    /// 读取请求体，分块交给 `onChunk`；返回 false 则中止。
    func readBody(length: Int64, onChunk: @escaping (Data) -> Bool, completion: @escaping (Bool) -> Void) {
        var remaining = length
        if !buffer.isEmpty {
            let take = buffer.prefix(Int(min(Int64(buffer.count), remaining)))
            buffer = Data()
            remaining -= Int64(take.count)
            if !onChunk(Data(take)) { completion(false); return }
        }
        func next() {
            if remaining <= 0 { completion(true); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: Int(min(Int64(HTTPConnection.chunkSize), remaining))) { [weak self] data, _, complete, error in
                guard let self, !self.closed else { completion(false); return }
                if let data, !data.isEmpty {
                    remaining -= Int64(data.count)
                    if !onChunk(data) { completion(false); return }
                }
                if remaining <= 0 { completion(true) }
                else if complete || error != nil { completion(false) }
                else { next() }
            }
        }
        next()
    }

    /// SSE 等长连接：持续读，读到 EOF 即视为客户端断开。
    func watchForDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil { self.close() } else { self.watchForDisconnect() }
        }
    }

    // MARK: Writing

    func send(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        guard !closed else { completion?(false); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
            completion?(error == nil)
        })
    }

    func sendHead(_ head: HTTPHead, completion: ((Bool) -> Void)? = nil) {
        send(head.serialized(), completion: completion)
    }

    func respond(_ head: HTTPHead, body: Data) {
        var head = head
        head.add("Content-Length", "\(body.count)")
        var payload = head.serialized()
        payload.append(body)
        send(payload) { [weak self] _ in self?.finish() }
    }

    func respondJSON<T: Encodable>(_ status: Int, _ value: T, headers: [(String, String)] = []) {
        var head = HTTPHead(status, headers)
        head.add("Content-Type", "application/json; charset=utf-8")
        head.add("Cache-Control", "no-store")
        respond(head, body: value.jsonData())
    }

    func respondError(_ status: Int, _ message: String) {
        respondJSON(status, ["error": message])
    }

    /// 发送完已排队的数据后关闭。
    func finish() {
        guard !closed else { return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func onClosed(_ handler: @escaping () -> Void) {
        queue.async {
            if self.closed { handler() } else { self.closeHandlers.append(handler) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let handlers = closeHandlers
        closeHandlers.removeAll()
        handlers.forEach { $0() }
        onClose?(self)
    }

    /// 可在任意线程调用。
    func cancel() { queue.async { self.close() } }

    var isClosed: Bool { closed }
}
