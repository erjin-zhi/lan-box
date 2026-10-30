import Network
import XCTest
@testable import LanBox

final class TerminationGateTests: XCTestCase {
    private func connection() -> HTTPConnection {
        // Never started: these tests do not open sockets or contact a server.
        HTTPConnection(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    }

    private func start(_ hub: ServerHub, connection: HTTPConnection) -> Transfer? {
        hub.startTransfer(.upload, clientID: "test", name: "received.txt", path: "received.txt", total: 10, connection: connection)
    }

    func testActiveTransferPreventsQuitWithoutClosingAdmission() throws {
        let hub = ServerHub()
        let connection = connection()
        let first = try XCTUnwrap(start(hub, connection: connection))
        XCTAssertFalse(hub.pauseTransfersIfIdle())
        let second = try XCTUnwrap(start(hub, connection: connection))
        hub.endTransfer(first, .completed)
        XCTAssertFalse(hub.pauseTransfersIfIdle())
        hub.endTransfer(second, .cancelled)
        XCTAssertTrue(hub.pauseTransfersIfIdle())
    }

    func testPreparingQuitRejectsTransfersAndCancelRestoresSharing() throws {
        let hub = ServerHub()
        let connection = connection()
        XCTAssertTrue(hub.pauseTransfersIfIdle())
        XCTAssertNil(start(hub, connection: connection))
        XCTAssertTrue(hub.allTransfers.isEmpty)

        hub.resumeTransfers()
        let transfer = try XCTUnwrap(start(hub, connection: connection))
        XCTAssertEqual(transfer.state, .active)
        hub.endTransfer(transfer, .completed)
    }

    func testStartingTransferAndPreparingQuitCannotBothWin() {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var transfer: Transfer?
            var paused = false
        }
        let hub = ServerHub()
        let connection = connection()
        for _ in 0..<80 {
            hub.resumeTransfers()
            let results = Results()
            let group = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                let transfer = hub.startTransfer(.upload, clientID: "test", name: "race.txt", path: "race.txt", total: 10, connection: connection)
                results.lock.withLock { results.transfer = transfer }
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                let paused = hub.pauseTransfersIfIdle()
                results.lock.withLock { results.paused = paused }
                group.leave()
            }
            start.signal()
            start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            let (transfer, paused) = results.lock.withLock { (results.transfer, results.paused) }
            XCTAssertNotEqual(transfer != nil, paused, "Quit and a new transfer must never both be admitted")
            if let transfer { hub.endTransfer(transfer, .completed) }
        }
    }
}
