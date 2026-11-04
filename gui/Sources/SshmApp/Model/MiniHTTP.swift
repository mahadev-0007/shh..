import Foundation
import Network

/// Just enough HTTP/1.1 for one JSON request and one JSON reply per connection.
///
/// It rides inside Tailscale's WireGuard tunnel, so plain HTTP is already
/// encrypted and authenticated end to end. Network.framework is used for the
/// client too: URLSession would apply App Transport Security and refuse plain
/// http to a tailnet name.
enum MiniHTTP {
    static let maxRequest = 32 * 1024

    struct Request {
        var method: String
        var path: String
        var body: Data
        /// The peer's address, as the socket saw it.
        var remoteIP: String?
    }

    struct Response {
        var status: Int
        var json: [String: Any]

        static func error(_ status: Int, _ message: String) -> Response {
            Response(status: status, json: ["error": message])
        }
    }

    static func ipString(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a):
            return a.rawValue.map { String($0) }.joined(separator: ".")
        case .ipv6(let a):
            // a v4-mapped v6 address is really the v4 one
            let b = [UInt8](a.rawValue)
            if b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                return b[12...].map { String($0) }.joined(separator: ".")
            }
            return "\(a)".components(separatedBy: "%").first
        case .name(let n, _):
            return n
        @unknown default:
            return nil
        }
    }

    /// Split "head\r\n\r\nbody" once the whole message (per Content-Length) is in.
    /// nil means keep reading.
    static func parse(_ data: Data) -> (head: [String], body: Data)? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(data: data[..<range.lowerBound], encoding: .utf8) ?? ""
        let lines = headText.components(separatedBy: "\r\n")
        var length = 0
        for l in lines.dropFirst() {
            let parts = l.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[range.upperBound...]
        guard body.count >= length else { return nil }
        return (lines, Data(body.prefix(length)))
    }

    static func encode(status: Int, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 429: reason = "Too Many Requests"
        default:  reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    // MARK: - server

    final class Server {
        typealias Reply = (Response, _ delivered: @escaping (Bool) -> Void) -> Void
        typealias Handler = (Request, @escaping Reply) -> Void

        private let listener: NWListener
        private let queue = DispatchQueue(label: "shh.sharing.http")
        private let handler: Handler

        /// Binds to exactly one local address, so the service is unreachable
        /// from any network but the one that address belongs to.
        init(host: String, port: UInt16, handler: @escaping Handler) throws {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                                     port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: params)
            self.handler = handler
        }

        func start(onState: @escaping (NWListener.State) -> Void) {
            listener.stateUpdateHandler = { s in DispatchQueue.main.async { onState(s) } }
            listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
            listener.start(queue: queue)
        }

        func stop() { listener.cancel() }

        private func accept(_ c: NWConnection) {
            c.start(queue: queue)
            // a client that connects and says nothing must not hold a socket open
            let timeout = DispatchWorkItem { c.cancel() }
            queue.asyncAfter(deadline: .now() + 10, execute: timeout)
            read(c, buffer: Data(), timeout: timeout)
        }

        private func read(_ c: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
            c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                [weak self] data, _, done, error in
                guard let self else { c.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if buf.count > MiniHTTP.maxRequest || error != nil {
                    timeout.cancel(); c.cancel(); return
                }
                guard let (head, body) = MiniHTTP.parse(buf) else {
                    if done { timeout.cancel(); c.cancel(); return }
                    self.read(c, buffer: buf, timeout: timeout)
                    return
                }
                // the request is in; how long the handler takes is its business
                // (it may be waiting on a person to click Allow)
                timeout.cancel()
                let first = head.first?.split(separator: " ") ?? []
                let req = Request(method: first.count > 0 ? String(first[0]) : "",
                                  path: first.count > 1 ? String(first[1]) : "",
                                  body: body,
                                  remoteIP: MiniHTTP.ipString(c.endpoint))
                self.handler(req) { resp, delivered in
                    let bytes = MiniHTTP.encode(status: resp.status, json: resp.json)
                    c.send(content: bytes, completion: .contentProcessed { err in
                        delivered(err == nil && c.state == .ready)
                        c.cancel()
                    })
                }
            }
        }
    }

    // MARK: - client

    enum ClientError: LocalizedError {
        case unreachable(String)
        case timedOut
        case badReply

        var errorDescription: String? {
            switch self {
            case .unreachable(let host):
                return "Couldn't reach \(host). Check that Tailscale is connected on both "
                     + "Macs and that this Mac can see the other one."
            case .timedOut: return "The other Mac didn't answer in time."
            case .badReply: return "The other Mac sent a reply shh doesn't understand."
            }
        }
    }

    /// POST a JSON body and call back on the main thread with (status, json).
    static func post(host: String, port: UInt16, path: String, json: [String: Any],
                     timeout: TimeInterval,
                     completion: @escaping (Result<(Int, [String: Any]), Error>) -> Void) {
        let queue = DispatchQueue(label: "shh.sharing.client")
        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var finished = false
        func finish(_ r: Result<(Int, [String: Any]), Error>) {
            guard !finished else { return }
            finished = true
            c.cancel()
            DispatchQueue.main.async { completion(r) }
        }
        queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(ClientError.timedOut)) }

        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "POST \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let request = Data(head.utf8) + body

        var buffer = Data()
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
                if let data { buffer.append(data) }
                if let (h, b) = parse(buffer) {
                    let status = Int(h.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
                    let obj = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any]
                    if let obj { finish(.success((status, obj))) }
                    else { finish(.failure(ClientError.badReply)) }
                    return
                }
                if done || error != nil { finish(.failure(ClientError.badReply)); return }
                receive()
            }
        }

        c.stateUpdateHandler = { s in
            switch s {
            case .ready:
                c.send(content: request, completion: .contentProcessed { err in
                    if err != nil { finish(.failure(ClientError.unreachable(host))) }
                })
                receive()
            case .failed, .waiting:
                finish(.failure(ClientError.unreachable(host)))
            default: break
            }
        }
        c.start(queue: queue)
    }

    /// Is something accepting TCP on host:port? Main-thread callback.
    static func probe(host: String, port: UInt16, timeout: TimeInterval = 2,
                      completion: @escaping (Bool) -> Void) {
        let queue = DispatchQueue(label: "shh.sharing.probe")
        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var finished = false
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            c.cancel()
            DispatchQueue.main.async { completion(ok) }
        }
        c.stateUpdateHandler = { s in
            switch s {
            case .ready: finish(true)
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        c.start(queue: queue)
    }
}
