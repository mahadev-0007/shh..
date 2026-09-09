import Foundation

/// How a child process ended.
///
/// SwiftTerm hands us the raw `waitpid` status word, not an exit code — see
/// `LocalProcess.processTerminated`, which does `waitpid(pid, &n, WNOHANG)` and
/// passes `n` straight through. For a normal exit of N that word is `N << 8`,
/// so comparing it against 255 (as this app did) never matched anything.
enum ExitStatus: Equatable {
    /// Exited of its own accord with this code. 0 means cleanly.
    case code(Int32)
    /// Killed by a signal.
    case signal(Int32)

    init(rawStatus: Int32) {
        let term = rawStatus & 0x7f
        if term == 0 {
            self = .code((rawStatus >> 8) & 0xff)
        } else if term == 0x7f {
            // stopped, not exited; treat as still-alive rather than a crash
            self = .code(0)
        } else {
            self = .signal(term)
        }
    }

    var isClean: Bool { self == .code(0) }

    /// A short human explanation, or nil when there is nothing useful to add.
    var detail: String? {
        switch self {
        case .code(0):   return nil
        case .code(5):   return "sshpass: wrong password"
        case .code(6):   return "host key not accepted — connect once by hand to trust it"
        case .code(255): return "ssh lost the connection or could not reach the host"
        case .code(127): return "command not found on the server"
        case .code(let c): return "exit \(c)"
        case .signal(let s): return "killed by signal \(s)"
        }
    }

    var label: String {
        switch self {
        case .code(let c):   return "exit \(c)"
        case .signal(let s): return "signal \(s)"
        }
    }

    /// Whether losing the session this way is worth retrying.
    ///
    /// Only transport failures. Retrying a rejected password or an untrusted
    /// host key just loops, and a clean exit means the user asked to leave.
    var shouldReconnect: Bool {
        switch self {
        case .code(255):     return true      // ssh's "connection failed/lost"
        case .signal:        return true      // killed under us, e.g. link died
        default:             return false
        }
    }
}
