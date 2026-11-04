import Foundation

/// The few things shh asks of the Tailscale CLI: who this machine is on the
/// tailnet, and who is behind a given tailnet address.
///
/// Everything here blocks, so call it off the main thread.
enum Tailscale {
    enum Failure: LocalizedError {
        case notInstalled
        case notRunning(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Tailscale isn't installed. Get it from tailscale.com/download."
            case .notRunning(let state):
                return state == "NeedsLogin"
                    ? "Tailscale is installed but not signed in."
                    : "Tailscale isn't connected (\(state))."
            case .failed(let s): return s
            }
        }
    }

    /// This machine on the tailnet.
    struct SelfNode: Equatable {
        var hostName: String
        /// MagicDNS name without the trailing dot, e.g. bob-mbp.tail1234.ts.net
        var dnsName: String
        var ipv4: String
    }

    /// The person and device behind a tailnet address, as Tailscale vouches.
    struct Peer: Equatable {
        var login: String
        var displayName: String
        var node: String
        /// Every tailnet address of that device (v4 and v6), without prefixes.
        var addresses: [String]
    }

    /// The standalone and App Store apps carry the CLI inside the bundle;
    /// Homebrew and the open-source build put it on the PATH.
    static var cli: String? {
        let bundled = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return Tools.which("tailscale")
    }

    static func selfNode() throws -> SelfNode {
        let json = try runJSON(["status", "--json", "--peers=false"])
        let state = json["BackendState"] as? String ?? "Unknown"
        guard state == "Running" else { throw Failure.notRunning(state) }
        guard let me = json["Self"] as? [String: Any],
              let ips = me["TailscaleIPs"] as? [String],
              let v4 = ips.first(where: { !$0.contains(":") })
        else { throw Failure.failed("Tailscale didn't report an address for this Mac.") }
        let dns = (me["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return SelfNode(hostName: me["HostName"] as? String ?? "", dnsName: dns, ipv4: v4)
    }

    static func whois(_ ip: String) throws -> Peer {
        let json = try runJSON(["whois", "--json", ip])
        guard let node = json["Node"] as? [String: Any],
              let user = json["UserProfile"] as? [String: Any],
              let login = user["LoginName"] as? String, !login.isEmpty
        else { throw Failure.failed("Tailscale doesn't know who \(ip) is.") }
        let addrs = (node["Addresses"] as? [String] ?? [])
            .map { $0.split(separator: "/").first.map(String.init) ?? $0 }
        let name = (node["ComputedName"] as? String)
            ?? (node["Name"] as? String ?? "").components(separatedBy: ".").first ?? ""
        return Peer(login: login,
                    displayName: user["DisplayName"] as? String ?? login,
                    node: name,
                    addresses: addrs.isEmpty ? [ip] : addrs)
    }

    private static func runJSON(_ args: [String]) throws -> [String: Any] {
        guard let cli else { throw Failure.notInstalled }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()

        // a wedged daemon must not wedge the caller
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        killer.cancel()

        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if msg.contains("doesn't appear to be running") || msg.contains("failed to connect") {
                throw Failure.notRunning("Stopped")
            }
            throw Failure.failed(msg.isEmpty ? "tailscale \(args[0]) failed." : msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.failed("Unexpected output from tailscale \(args[0]).")
        }
        return obj
    }
}
