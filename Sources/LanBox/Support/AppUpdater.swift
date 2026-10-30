import AppKit
import Combine
import Sparkle

/// One updater for both the app menu and the menu bar panel.
@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isAvailable = false
    @Published private(set) var unavailableReason: String?

    private var controller: SPUStandardUpdaterController?
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        unavailableReason = "请使用打包后的 LanBox.app 检查更新"
        super.init()
    }

    /// Called after the application finishes launching, not during view construction.
    func start() {
        guard controller == nil else { return }
        if let reason = Self.configurationIssue(in: Bundle.main) {
            unavailableReason = reason
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &cancellables)

        // Starting the updater directly lets us keep configuration errors in the UI
        // instead of presenting Sparkle's delayed developer-error alert.
        do {
            try updater.start()
            isAvailable = true
            unavailableReason = nil
        } catch {
            unavailableReason = "自动更新暂不可用：\(error.localizedDescription)"
            canCheckForUpdates = false
        }
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard isAvailable, canCheckForUpdates else { return }
        NSApp.activate()
        controller?.checkForUpdates(sender)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        // Sparkle owns persistence and reschedules its own timer after this change.
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isAvailable && canCheckForUpdates
    }

    static func configurationIssue(in bundle: Bundle) -> String? {
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else {
            return "请使用打包后的 LanBox.app 检查更新"
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host?.isEmpty == false,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            return "此版本未配置自动更新"
        }
        return nil
    }
}
