import AppKit
import Sparkle

/// Wraps Sparkle. The app is ad-hoc signed — there is no Developer ID — so
/// updates are authenticated by the EdDSA signature on each archive rather than
/// by a code-signing identity. Sparkle accepts either; the key pair lives in the
/// release machine's keychain and the public half is baked into Info.plist as
/// SUPublicEDKey.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    /// True once a feed URL and a public key are actually configured — an
    /// unreleased local build has neither, and we shouldn't offer a menu item
    /// that can only fail.
    private(set) var isConfigured = false

    private override init() { super.init() }

    func start() {
        let feed = AppVersion.feedURL
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !feed.isEmpty && !key.isEmpty
        guard isConfigured else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller?.updater.automaticallyChecksForUpdates =
            AppModel.shared.settings.automaticUpdates
        controller?.updater.updateCheckInterval = 60 * 60 * 6
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        guard let controller else {
            let a = NSAlert()
            a.messageText = "Updates aren't configured for this build"
            a.informativeText = "This copy was built locally. Released builds carry a feed URL "
                              + "and a public key, and update themselves."
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    func setAutomatic(_ on: Bool) {
        AppModel.shared.updateSettings { $0.automaticUpdates = on }
        controller?.updater.automaticallyChecksForUpdates = on
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    // MARK: - SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        let feed = AppVersion.feedURL
        return feed.isEmpty ? nil : feed
    }

    /// Sessions are live ssh connections; relaunching under them would drop
    /// work. Tell Sparkle to wait rather than terminating out from under one.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let live = (NSApp.delegate as? AppDelegate)?
            .main?.root.shell.terminals.sessions.filter(\.isRunning).count ?? 0
        guard live > 0 else { return false }

        let a = NSAlert()
        a.messageText = "\(live) session\(live == 1 ? " is" : "s are") still running"
        a.informativeText = "Installing now closes them. Install and relaunch anyway?"
        a.alertStyle = .warning
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            installHandler()
        }
        return true
    }
}
