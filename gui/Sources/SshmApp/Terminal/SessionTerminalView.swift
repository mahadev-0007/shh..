import AppKit
import SwiftTerm

/// The terminal for one session, with the image bridge wired into paste and
/// drag-and-drop. Text pastes behave exactly as before.
final class SessionTerminalView: LocalProcessTerminalView {
    /// Supplied by the session: where to upload, and how to report.
    var uploadTarget: (() -> (controlPath: String, target: String)?)?
    var onStatus: ((String, Bool) -> Void)?

    private var busy = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - paste

    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageData(from: sender) == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageData(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let data = imageData(from: sender) else {
            return super.performDragOperation(sender)
        }
        send(image: data)
        return true
    }

    private func imageData(from sender: NSDraggingInfo) -> Data? {
        guard AppModel.shared.settings.pasteImagesToServer else { return nil }
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
}
