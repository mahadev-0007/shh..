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

    // MARK: - files

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp"]

    /// Local files on a pasteboard that should go up as files rather than as an
    /// image. A single image file keeps the image path (it is normalized to
    /// PNG, which every agent can read); anything else — a PDF, a folder,
    /// several files at once — is sent as-is.
    ///
    /// Checked before `hasImage`: Finder puts the file's *icon* on the
    /// pasteboard as TIFF next to the URL, so copying a PDF would otherwise
    /// upload a picture of a PDF icon.
    static func fileURLs(from pb: NSPasteboard) -> [URL]? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        if urls.count == 1, imageExtensions.contains(urls[0].pathExtension.lowercased()) {
            return nil
        }
        return urls
    }

    /// Upload local files or folders over sftp and call back on the main queue
    /// with their remote paths, in the order given.
    ///
    /// Each drop gets a directory of its own so the original names survive and
    /// two drops of `notes.txt` can't overwrite each other.
    static func upload(files urls: [URL], controlPath: String, target: String,
                       completion: @escaping (Result<[String], Error>) -> Void) {
        let script = "d=${XDG_CACHE_HOME:-$HOME/.cache}/sshm-clip/drop-\(Self.stamp()); "
                   + "mkdir -p \"$d\" && printf '%s' \"$d\""
        // ride the session's master: no handshake, and no password to supply
        let mux = ["-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no",
                   "-o", "BatchMode=yes"]

        RemoteExec.run(Tools.ssh, args: mux + [target, script], password: nil) { made in
            let dir: String
            switch made {
            case .failure(let e): completion(.failure(e)); return
            case .success(let out):
                dir = out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !dir.isEmpty else { completion(.failure(Failure.uploadFailed(""))); return }
            }
            let remote = urls.map { RemoteFiles.join(dir, $0.lastPathComponent) }
            let batch = zip(urls, remote).map {
                "put -r \(RemoteFiles.sftpQuote($0.path)) \(RemoteFiles.sftpQuote($1))"
            }
            let input = Data((batch.joined(separator: "\n") + "\n").utf8)
            RemoteExec.run(Tools.sftp, args: mux + ["-b", "-", target],
                           password: nil, input: input) { sent in
                completion(sent.map { _ in remote })
            }
        }
    }

    /// Paths as they should be typed into a shell or an agent prompt: bare when
    /// that is unambiguous, single-quoted when a space or metacharacter would
    /// split or expand them.
    static func typed(_ paths: [String]) -> String {
        let plain = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,@%:=")
        return paths.map {
            $0.unicodeScalars.allSatisfy(plain.contains) ? $0 : Shell.quote($0)
        }.joined(separator: " ")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: Date()))-\(Int.random(in: 1000...9999))"
    }
}
