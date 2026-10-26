import AppKit
import SwiftTerm

/// The terminal for one session, with the image and file bridge wired into
/// paste and drag-and-drop. Text pastes behave exactly as before.
final class SessionTerminalView: LocalProcessTerminalView {
    /// Supplied by the session: where to upload, and how to report.
    var uploadTarget: (() -> (controlPath: String, target: String)?)?
    var onStatus: ((String, Bool) -> Void)?
    /// Something on the far side wants attention: (title, body, kind).
    var onNotify: ((String, String, NotificationKind) -> Void)?
    /// What to call this session in a notification.
    var sessionTitle: () -> String = { "Session" }

    private var busy = false

    // idle detection: a burst of output followed by silence
    private var lastOutput = Date.distantPast
    private var burstStarted: Date?
    private var idleTimer: Timer?
    private var idleArmed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        installOSCHandlers()
    }

    deinit { idleTimer?.invalidate() }

    // MARK: - attention triggers

    /// BEL. `TerminalView.bell(source:)` is `open`, so this is ordinary class
    /// dispatch — unlike `TerminalDelegate.notify`, whose conformance is
    /// satisfied by a protocol-extension default and could never be overridden
    /// here.
    override func bell(source: Terminal) {
        if AppModel.shared.settings.bellSound { NSSound.beep() }
        onNotify?(sessionTitle(), "Ready for you", .bell)
    }

    /// OSC 9 and OSC 777 carry real notifications from the far side.
    ///
    /// These go through the parser's public handler registry rather than the
    /// `notify` delegate: custom handlers are consulted before the built-ins,
    /// and the registry sidesteps the witness-table problem entirely.
    private(set) var oscInstalled = false

    private func installOSCHandlers() {
        guard let parser = terminal?.parser else { return }
        oscInstalled = true

        // OSC 777;notify;title;body
        parser.oscHandlers[777] = { [weak self] data in
            guard let self,
                  let text = String(bytes: data, encoding: .utf8) else { return }
            let parts = text.components(separatedBy: ";")
            guard parts.count >= 3, parts[0] == "notify" else { return }
            let body = parts[2...].joined(separator: ";")
            DispatchQueue.main.async {
                self.onNotify?(parts[1].isEmpty ? self.sessionTitle() : parts[1],
                               body, .remote)
            }
        }

        // OSC 9 is overloaded: ConEmu uses `9;4;state;pct` for progress, while
        // iTerm2 treats the whole payload as notification text. Registering
        // here takes over SwiftTerm's progress handling, so pass that case on.
        parser.oscHandlers[9] = { [weak self] data in
            guard let self,
                  let text = String(bytes: data, encoding: .utf8) else { return }
            guard !text.hasPrefix("4;") else { return }   // progress, not a message
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                self.onNotify?(self.sessionTitle(), text, .remote)
            }
        }
    }

    /// Every byte from the pty passes through here, which is the cheapest place
    /// to notice that a long-running command has gone quiet.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        guard AppModel.shared.settings.notifyOnIdle else { return }

        let now = Date()
        // a gap this long means the previous burst is over
        if now.timeIntervalSince(lastOutput) > Self.idleGap { burstStarted = now }
        lastOutput = now

        // only arm once output has been sustained; an idle shell echoing a
        // keystroke must never queue a notification
        if let start = burstStarted, now.timeIntervalSince(start) >= Self.burstMin {
            idleArmed = true
        }
        guard idleArmed else { return }

        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleGap,
                                         repeats: false) { [weak self] _ in
            guard let self, self.idleArmed else { return }
            self.idleArmed = false
            self.burstStarted = nil
            self.onNotify?(self.sessionTitle(), "Finished", .idle)
        }
    }

    /// Sustained output before idle counts as "a long run".
    private static let burstMin: TimeInterval = 3
    /// Silence after that which counts as finished.
    private static let idleGap: TimeInterval = 15
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - paste

    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
        if AppModel.shared.settings.pasteImagesToServer,
           let urls = ClipboardBridge.fileURLs(from: pb) {
            send(files: urls)
            return
        }
        guard AppModel.shared.settings.pasteImagesToServer,
              ClipboardBridge.hasImage(pb) else {
            super.paste(sender)
            return
        }
        guard let data = ClipboardBridge.imageData(from: pb) else {
            super.paste(sender)      // looked like an image, wasn't one
            return
        }
        send(image: data)
    }

    // MARK: - drag and drop

    // Hold Option while dropping to get the old behaviour: the local path typed
    // in, nothing uploaded.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        uploads(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        uploads(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if bridging, let urls = ClipboardBridge.fileURLs(from: sender.draggingPasteboard) {
            send(files: urls)
            return true
        }
        guard let data = imageData(from: sender) else {
            return super.performDragOperation(sender)
        }
        send(image: data)
        return true
    }

    private var bridging: Bool {
        AppModel.shared.settings.pasteImagesToServer
            && !NSEvent.modifierFlags.contains(.option)
    }

    private func uploads(_ sender: NSDraggingInfo) -> Bool {
        guard bridging else { return false }
        return ClipboardBridge.fileURLs(from: sender.draggingPasteboard) != nil
            || imageData(from: sender) != nil
    }

    private func imageData(from sender: NSDraggingInfo) -> Data? {
        guard bridging else { return nil }
        return ClipboardBridge.imageData(from: sender.draggingPasteboard)
    }

    // MARK: - upload

    private func send(image data: Data) {
        guard !busy, let dest = uploadTarget?() else { NSSound.beep(); return }
        busy = true
        onStatus?("Uploading image…", false)

        ClipboardBridge.upload(data, controlPath: dest.controlPath, target: dest.target) {
            [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let path):
                // Type the path into the session. The system clipboard is left
                // exactly as the user had it.
                self.send(txt: path)
                self.onStatus?("Image uploaded — path pasted into the session", false)
            case .failure(let e):
                NSSound.beep()
                self.onStatus?(e.localizedDescription, true)
            }
        }
    }

    private func send(files urls: [URL]) {
        guard !busy, let dest = uploadTarget?() else { NSSound.beep(); return }
        busy = true
        let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) files"
        onStatus?("Uploading \(what)…", false)

        ClipboardBridge.upload(files: urls, controlPath: dest.controlPath,
                               target: dest.target) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let paths):
                self.send(txt: ClipboardBridge.typed(paths))
                self.onStatus?("Uploaded \(what) — path pasted into the session", false)
            case .failure(let e):
                NSSound.beep()
                self.onStatus?(e.localizedDescription, true)
            }
        }
    }
}
