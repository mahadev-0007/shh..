import AppKit
import AVFoundation
import Network

/// Lends this Mac's microphone to Claude Code running on the server.
///
/// Claude Code's voice mode records on the machine it runs on. On Linux, with
/// no sound card, it falls back to spawning `arecord -f S16_LE -r 16000 -c 1
/// -t raw -` and reading raw PCM from its stdout. So the bridge is:
///
///   server: ~/.local/share/shh/bin/arecord (a shim, first on the session's
///           PATH) → 127.0.0.1:<remote port> on the server
///   ssh:    a remote forward on the session's control master
///   Mac:    this listener on 127.0.0.1 → AVAudioEngine → 16 kHz mono s16le
///
/// The mic is only open while a shim is connected in `record` mode, i.e. while
/// you are holding the voice key; macOS shows its orange dot for exactly that
/// long. The forwarded port is reachable by anyone on the server's loopback, so
/// every connection must present a per-launch token kept in a 0700 directory
/// in the user's home.
final class VoiceBridge {
    static let shared = VoiceBridge()

    /// Where the shim lives on the server. Sessions put it first on PATH.
    static let remoteBin = "$HOME/.local/share/shh/bin"

    private let token: String = {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    private let queue = DispatchQueue(label: "shh.voice")
    private var listener: NWListener?
    /// The local port, once the listener is up. Read from any thread.
    private var localPort: UInt16? {
        get { queue.sync { _port } }
    }
    private var _port: UInt16?

    // recording state, touched only on `queue`
    private var engine: AVAudioEngine?
    private var recording: NWConnection?

    /// Control masters that already carry a forward to us, by master pid, so a
    /// shared connection with five tabs on it gets one forward, not five.
    private var forwarded: [String: (pid: String, remotePort: String)] = [:]
    private let forwardLock = NSLock()

    private var warnedDenied = false

    // MARK: - listening

    private func ensureListening() {
        queue.async { [self] in
            guard listener == nil else { return }
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params) else {
                NSLog("shh voice: could not create listener")
                return
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self._port = l?.port?.rawValue
                case .failed(let e):
                    NSLog("shh voice: listener failed: \(e)")
                    self._port = nil
                    self.listener?.cancel()
                    self.listener = nil
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        readHeader(c, buffer: Data())
    }

    /// `SHH-VOICE <token> <probe|record>\n`, and nothing else is accepted.
    private func readHeader(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let nl = buf.firstIndex(of: 0x0A) else {
                if done || err != nil || buf.count > 256 { c.cancel() }
                else { self.readHeader(c, buffer: buf) }
                return
            }
            let line = String(decoding: buf[..<nl], as: UTF8.self)
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 3, parts[0] == "SHH-VOICE",
                  Self.same(parts[1], self.token) else { c.cancel(); return }
            switch parts[2] {
            case "probe":
                c.send(content: Data("OK\n".utf8), completion: .contentProcessed { _ in
                    c.cancel()
                })
            case "record":
                self.record(to: c)
            default:
                c.cancel()
            }
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - recording

    private func record(to c: NWConnection) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine(for: c)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                self?.queue.async {
                    if ok { self?.startEngine(for: c) } else { c.cancel(); self?.denied() }
                }
            }
        default:
            c.cancel()
            denied()
        }
    }

    private func startEngine(for c: NWConnection) {
        stopEngine()       // one talker at a time; the newest press wins
        recording = c

        // The shim never writes after its header, so the stream ending means
        // Claude stopped recording and killed it.
        watchForClose(c)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000, channels: 1,
                                            interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            NSLog("shh voice: no usable input device")
            c.cancel(); recording = nil
            return
        }
        let ratio = outFormat.sampleRate / inFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData
            else { return }
            let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
            c.send(content: data, completion: .contentProcessed { e in
                if e != nil { self?.queue.async { self?.stop(c) } }
            })
        }

        do {
            try engine.start()
            self.engine = engine
        } catch {
            NSLog("shh voice: could not start the microphone: \(error)")
            input.removeTap(onBus: 0)
            c.cancel(); recording = nil
        }
    }

    private func watchForClose(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
            guard let self else { return }
            if done || err != nil { self.stop(c) } else { self.watchForClose(c) }
        }
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.stop(c)
            default: break
            }
        }
    }

    /// Stop only if `c` is still the one being recorded for.
    private func stop(_ c: NWConnection) {
        guard recording === c else { return }
        stopEngine()
    }

    private func stopEngine() {
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        recording?.cancel()
        recording = nil
    }

    private func denied() {
        DispatchQueue.main.async { [self] in
            guard !warnedDenied else { NSSound.beep(); return }
            warnedDenied = true
            let a = NSAlert()
            a.messageText = "shh can't use the microphone"
            a.informativeText = "Voice mode in a remote session records through this Mac's "
                + "microphone. Allow shh under System Settings › Privacy & Security › "
                + "Microphone, then try again."
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Not Now")
            if a.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:"
                             + "com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - per-session setup

    /// Wire a freshly launched session to the bridge: wait for its control
    /// master (a password may still be being typed), add the remote forward,
    /// and install the shim plus where-to-connect on the server.
    func attach(_ session: SSHSession) {
        guard AppModel.shared.settings.voiceInput else { return }
        ensureListening()
        let server = session.server
        let ctl = session.controlPath

        DispatchQueue.global(qos: .utility).async { [weak self, weak session] in
            guard let self else { return }
            // up to two minutes to finish logging in
            var pid: String?
            for _ in 0..<120 {
                guard let s = session, s.isRunning else { return }
                if self.localPort != nil, let p = self.masterPID(ctl: ctl, server: server) {
                    pid = p; break
                }
                Thread.sleep(forTimeInterval: 1)
            }
            guard let pid, let local = self.localPort else { return }

            self.forwardLock.lock()
            var remote = self.forwarded[ctl].flatMap { $0.pid == pid ? $0.remotePort : nil }
            self.forwardLock.unlock()

            if remote == nil {
                let r = Self.ssh(["-o", "ControlPath=\(ctl)", "-O", "forward",
                                  "-R", "127.0.0.1:0:127.0.0.1:\(local)", server.target])
                let port = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard r.status == 0, !port.isEmpty, port.allSatisfy(\.isNumber) else {
                    NSLog("shh voice: remote forward refused (\(r.status)): \(r.err)")
                    return
                }
                remote = port
                self.forwardLock.lock()
                self.forwarded[ctl] = (pid, port)
                self.forwardLock.unlock()
            }
            guard let remote else { return }

            let install = "umask 077; d=\"$HOME/.cache/shh-voice\"; b=\"\(Self.remoteBin)\"; "
                + "mkdir -p \"$d\" \"$b\" && cat > \"$b/.arecord.$$\" "
                + "&& chmod 755 \"$b/.arecord.$$\" && mv -f \"$b/.arecord.$$\" \"$b/arecord\" "
                + "&& printf '%s\\n' \(remote) > \"$d/port\" "
                + "&& printf '%s\\n' \(self.token) > \"$d/token\""
            let r = Self.ssh(["-o", "ControlPath=\(ctl)", "-o", "ControlMaster=no",
                              "-p", server.port, server.target,
                              "sh -c \(Shell.quote(install))"],
                             input: Data(Self.shim.utf8))
            if r.status != 0 { NSLog("shh voice: could not install the shim: \(r.err)") }
        }
    }

    /// The control master's pid, or nil if it isn't up yet.
    private func masterPID(ctl: String, server: Server) -> String? {
        let r = Self.ssh(["-o", "ControlPath=\(ctl)", "-O", "check", server.target])
        guard r.status == 0 else { return nil }
        // "Master running (pid=12345)"
        let text = r.err + r.out
        guard let open = text.range(of: "pid="),
              let close = text[open.upperBound...].firstIndex(of: ")") else { return "?" }
        return String(text[open.upperBound..<close])
    }

    private static func ssh(_ args: [String], input: Data? = nil)
        -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Tools.ssh)
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return (-1, "", "\(error)") }
        if let input {
            inp.fileHandleForWriting.write(input)
            try? inp.fileHandleForWriting.close()
        }
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }

    // MARK: - the server side

    /// Stands in for `arecord`. Claude Code calls it three ways: `--version` to
    /// see it exists, `… /dev/null` as a quick probe, and `… -` to record raw
    /// PCM to stdout until it sends SIGTERM. The record path ends in `exec cat`,
    /// so that SIGTERM closes the socket and the Mac's mic goes off with it.
    /// When shh isn't reachable it hands over to the real arecord, if any.
    static let shim = #"""
    #!/bin/sh
    # shh voice bridge: lets Claude Code's voice mode hear the Mac's microphone
    # over the SSH connection. Installed and refreshed by shh.
    self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    real() {
      old_ifs=$IFS; IFS=:
      for d in $PATH; do
        [ "$d" = "$self_dir" ] && continue
        if [ -x "$d/arecord" ]; then IFS=$old_ifs; exec "$d/arecord" "$@"; fi
      done
      IFS=$old_ifs
      echo "arecord: no microphone here and shh's voice bridge is not connected" >&2
      exit 1
    }
    case "$1" in --version|-V) echo "arecord: shh voice bridge"; exit 0 ;; esac
    dir="$HOME/.cache/shh-voice"
    port=$(cat "$dir/port" 2>/dev/null); token=$(cat "$dir/token" 2>/dev/null)
    case "$port" in ''|*[!0-9]*) real "$@" ;; esac
    [ -n "$token" ] || real "$@"
    command -v bash >/dev/null 2>&1 || real "$@"
    last=; for a in "$@"; do last=$a; done
    bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 3
      printf "SHH-VOICE %s probe\n" "$2" >&3
      IFS= read -r -t 3 r <&3; [ "$r" = OK ]' sh "$port" "$token" 2>/dev/null || real "$@"
    [ "$last" = /dev/null ] && exit 0
    exec bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
      printf "SHH-VOICE %s record\n" "$2" >&3
      exec cat <&3' sh "$port" "$token"

    """#
}
