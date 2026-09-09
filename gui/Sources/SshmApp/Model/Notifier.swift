import AppKit
import UserNotifications

/// Why a session is asking for attention.
enum NotificationKind: String {
    case bell            // BEL — what Claude Code and most agents ring
    case remote          // OSC 9 / OSC 777, a real notification from the far side
    case idle            // output went quiet after a long run
    case disconnected    // the link dropped
    case reconnected

    var isEnabled: Bool {
        let s = AppModel.shared.settings
        switch self {
        case .bell:                       return s.notifyOnBell
        case .remote:                     return s.notifyOnRemote
        case .idle:                       return s.notifyOnIdle
        case .disconnected, .reconnected: return s.notifyOnDisconnect
        }
    }
}

/// macOS notifications for sessions you aren't looking at.
///
/// Authorization is requested on the first real trigger rather than at launch,
/// so the permission prompt arrives with some context instead of on a cold
/// start. If it is refused, fall back to bouncing the Dock icon — the point is
/// to be noticed, and a denied banner shouldn't mean silence.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Ask the app to bring a session forward; wired up by the shell.
    var onActivateSession: ((String) -> Void)?

    private var authorized: Bool?
    private var asking = false
    /// Sessions with something unseen, for the Dock badge.
    private var pending: Set<String> = []

    private override init() { super.init() }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post a notification for a session, unless the user is already looking at it.
    func notify(sessionID: String, title: String, body: String,
                kind: NotificationKind, isVisible: Bool) {
        guard kind.isEnabled else { return }
        // The whole rule: don't tell someone what they are already watching.
        guard !(isVisible && NSApp.isActive && (NSApp.keyWindow != nil)) else { return }

        pending.insert(sessionID)
        updateBadge()

        withAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else { self.fallbackAlert(); return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = kind == .bell ? .default : nil
            content.userInfo = ["sessionID": sessionID]
            content.threadIdentifier = sessionID

            let request = UNNotificationRequest(
                identifier: "\(sessionID)-\(kind.rawValue)-\(Date().timeIntervalSince1970)",
                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func clear(sessionID: String) {
        guard pending.remove(sessionID) != nil else { return }
        updateBadge()
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [])
    }

    private func updateBadge() {
        NSApp.dockTile.badgeLabel = pending.isEmpty ? nil : "\(pending.count)"
    }

    private func fallbackAlert() {
        DispatchQueue.main.async {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func withAuthorization(_ body: @escaping (Bool) -> Void) {
        if let authorized { body(authorized); return }
        guard !asking else { body(false); return }
        asking = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.asking = false
                    self?.authorized = granted
                    body(granted)
                }
            }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Banners while the app is frontmost. The visibility rule above has
    /// already decided this is worth showing, so don't let macOS suppress it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["sessionID"] as? String {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.onActivateSession?(id)
            }
        }
        handler()
    }
}
