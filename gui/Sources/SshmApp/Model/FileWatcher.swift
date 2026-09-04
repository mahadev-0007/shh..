import Foundation

/// Watches one file and calls back on the main queue. An atomic save replaces
/// the inode, so the source has to be torn down and re-armed on delete/rename —
/// that is the whole reason this is not three lines.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var rearming = false

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { source?.cancel() }

    private func arm() {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // the file may not exist yet; try again shortly
            scheduleRearm()
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let s = self.source else { return }
            let flags = s.data
            self.onChange()
            if flags.contains(.delete) || flags.contains(.rename) { self.scheduleRearm() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleRearm() {
        guard !rearming else { return }   // never stack re-arms; each leaks an fd
        rearming = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.rearming = false
            self?.arm()
        }
    }
}

/// Writes a file atomically at mode 0600 and remembers what it wrote, so the
/// watcher can tell its own saves apart from someone else's edit.
final class AtomicFile {
    let url: URL
    private(set) var lastWritten: Data?

    init(url: URL) { self.url = url }

    func read() -> Data? { try? Data(contentsOf: url) }

    /// True when the bytes on disk are exactly what we last wrote — i.e. the
    /// watcher fired for our own save and the model does not need reloading.
    func isOwnWrite(_ data: Data?) -> Bool {
        guard let d = data, let l = lastWritten else { return false }
        return d == l
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        do {
            try data.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            lastWritten = data
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}
