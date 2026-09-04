import AppKit

/// Sends an image to the server over a live session's control socket and hands
/// back the remote path.
///
/// Deliberately *not* a clipboard watcher. The bash version polls the pasteboard
/// and overwrites it with the remote path the moment any image appears, which
/// quietly destroys your local copy/paste — copy a PNG in Finder to paste
/// somewhere else and you get a server path instead. Here the upload happens
/// only when you paste or drop into a session, and the system clipboard is
/// never written to at all: the path goes straight into the terminal, which is
/// where you wanted it anyway.
enum ClipboardBridge {

    enum Failure: LocalizedError {
        case noImage
        case encodeFailed
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .noImage:       return "There is no image on the clipboard."
            case .encodeFailed:  return "That image could not be converted to PNG."
            case .uploadFailed(let s):
                return s.isEmpty ? "The upload failed." : s
            }
        }
    }

    /// PNG bytes for whatever is on a pasteboard, if it holds an image at all.
    ///
    /// A file URL only counts when it actually points at an image — copying a
    /// PDF or a folder in Finder must not look like an image to us.
    static func imageData(from pb: NSPasteboard) -> Data? {
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first,
           ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp"]
               .contains(url.pathExtension.lowercased()),
           let img = NSImage(contentsOf: url) {
            return png(from: img)
        }
        // raw pixels: a screenshot taken straight to the clipboard
        for type in [NSPasteboard.PasteboardType.png,
                     NSPasteboard.PasteboardType.tiff] {
            if let d = pb.data(forType: type) {
                if type == .png { return d }
                if let img = NSImage(data: d) { return png(from: img) }
            }
        }
        return nil
    }

    static func hasImage(_ pb: NSPasteboard) -> Bool {
        // cheap check first: don't decode anything just to answer "is it text?"
        let types = pb.types ?? []
        if types.contains(.png) || types.contains(.tiff) { return true }
        guard let urls = pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first else { return false }
        return ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp"]
            .contains(url.pathExtension.lowercased())
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Upload PNG bytes and call back on the main queue with the remote path.
    ///
    /// Rides the session's existing control socket, so there is no second
    /// handshake and no second password prompt.
    static func upload(_ data: Data, controlPath: String, target: String,
                       completion: @escaping (Result<String, Error>) -> Void) {
        let name = "clip-\(Self.stamp()).png"
        let script = "d=${XDG_CACHE_HOME:-$HOME/.cache}/sshm-clip; mkdir -p \"$d\" && "
                   + "cat > \"$d/\(name)\" && printf '%s' \"$d/\(name)\""

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            let stdin = Pipe(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: Tools.ssh)
            p.arguments = ["-S", controlPath, "-o", "BatchMode=yes", target, script]
            p.standardInput = stdin
            p.standardOutput = out
            p.standardError = err

            do { try p.run() } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            stdin.fileHandleForWriting.write(data)
            try? stdin.fileHandleForWriting.close()

            let path = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            p.waitUntilExit()

            DispatchQueue.main.async {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus == 0, !trimmed.isEmpty {
                    completion(.success(trimmed))
                } else {
                    completion(.failure(Failure.uploadFailed(
                        errText.components(separatedBy: "\n")
                            .filter { !$0.isEmpty }.last ?? "")))
                }
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: Date()))-\(Int.random(in: 1000...9999))"
    }
}
