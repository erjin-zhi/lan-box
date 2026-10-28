import Foundation
import Network

final class HTTPServer: @unchecked Sendable {
    enum State: Equatable { case stopped, starting, running(port: UInt16), failed(String) }

    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "lanbox.listener")
    private let handler: (HTTPRequest, HTTPConnection) -> Void
    var onStateChange: ((State) -> Void)?

    init(handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        self.handler = handler
    }

    /// 从首选端口开始依次尝试，直到绑定成功。
    func start(preferredPort: UInt16, attempts: Int = 20) {
        stop()
        onStateChange?(.starting)
        tryListen(port: preferredPort, remaining: attempts)
    }

    private func tryListen(port: UInt16, remaining: Int) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: params, on: nwPort) else {
            retry(port: port, remaining: remaining, reason: "无法创建监听端口")
            return
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.running(port: listener?.port?.rawValue ?? port))
            case .failed(let error):
                listener?.cancel()
                if self.listener === listener {
                    self.listener = nil
                    self.retry(port: port, remaining: remaining, reason: error.localizedDescription)
                }
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func retry(port: UInt16, remaining: Int, reason: String) {
        if remaining > 1 {
            tryListen(port: port &+ 1, remaining: remaining - 1)
        } else {
            onStateChange?(.failed(reason))
        }
    }

    private func accept(_ nw: NWConnection) {
        let conn = HTTPConnection(nw)
        conn.onRequest = handler
        conn.onClose = { [weak self] c in
            guard let self else { return }
            self.lock.withLock { _ = self.connections.removeValue(forKey: c.id) }
        }
        lock.withLock { connections[conn.id] = conn }
        conn.start()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let all = lock.withLock { Array(connections.values) }
        all.forEach { $0.cancel() }
        onStateChange?(.stopped)
    }
}
