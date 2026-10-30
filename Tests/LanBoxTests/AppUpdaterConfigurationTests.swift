import XCTest
@testable import LanBox

@MainActor
final class AppUpdaterConfigurationTests: XCTestCase {
    private func withApp(feed: String?, key: String?, _ check: (Bundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var info: [String: Any] = [
            "CFBundleIdentifier": "app.lanbox.test.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
        ]
        info["SUFeedURL"] = feed
        info["SUPublicEDKey"] = key
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
        try check(XCTUnwrap(Bundle(url: root)))
    }

    func testUnbundledExecutionDoesNotStartUpdater() {
        XCTAssertNotNil(AppUpdater.configurationIssue(in: .main))
    }

    func testOnlyCompleteHTTPSConfigurationCanStartUpdater() throws {
        let publicKey = Data(repeating: 0, count: 32).base64EncodedString()
        try withApp(feed: "https://example.com/appcast.xml", key: publicKey) {
            XCTAssertNil(AppUpdater.configurationIssue(in: $0))
        }
        try withApp(feed: "http://example.com/appcast.xml", key: publicKey) {
            XCTAssertNotNil(AppUpdater.configurationIssue(in: $0))
        }
        try withApp(feed: "https://example.com/appcast.xml", key: nil) {
            XCTAssertNotNil(AppUpdater.configurationIssue(in: $0))
        }
    }
}
