import AppKit
import Sparkle

/// Runs only inside disposable apps created by scripts/test-updater.sh.
/// No LanBox bundle, preferences, files, or running process is targeted.
@MainActor
final class UpdaterSmoke: NSObject, NSApplicationDelegate, SPUUserDriver, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private let bundle = Bundle.main

    private func record(_ event: String) {
        guard let path = bundle.object(forInfoDictionaryKey: "SmokeLogPath") as? String else { return }
        let line = Data((event + "\n").utf8)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    private func errorChain(_ error: Error) -> String {
        let error = error as NSError
        let current = "\(error.domain):\(error.code):\(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return current + " <- " + errorChain(underlying)
        }
        return current
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        record("launched:\(version)")
        guard version == "1" else {
            record("relaunched-new-version")
            NSApp.terminate(nil)
            return
        }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch {
            record("start-error:" + errorChain(error))
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        record("termination-request")
        return .terminateNow
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { record("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("found:\(appcastItem.versionString):signature-status=\(appcastItem.signingValidationStatus.rawValue)")
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { record("notes-error:" + errorChain(error)) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("not-found:" + errorChain(error))
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("error:" + errorChain(error))
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { record("download-started") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { record("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("ready-to-install")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        record("installing:terminated=\(applicationTerminated)")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        record("installed:relaunched=\(relaunched)")
        acknowledgement()
    }
    func dismissUpdateInstallation() { record("dismissed") }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { record("aborted:" + errorChain(error)) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = UpdaterSmoke()
    app.delegate = delegate
    app.run()
}
