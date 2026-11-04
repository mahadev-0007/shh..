import Foundation

/// The guest's half: turn an invite link into a working server entry.
enum JoinInvite {
    enum Failure: LocalizedError {
        case refused(String)
        case hostKeyMismatch
        case keygen

        var errorDescription: String? {
            switch self {
            case .refused(let s): return s
            case .hostKeyMismatch:
                return "The Mac that answered isn't the one that made this invite (its host "
                     + "key doesn't match). Nothing was saved."
            case .keygen: return "Couldn't create an ssh key for this connection."
            }
        }
    }

    /// Make a key, redeem the invite, trust the host key, save the server.
    /// Calls back on the main thread with the new server's slug.
    static func redeem(_ invite: InviteCode, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let keyName = "shh-" + Slug.make(invite.dnsName.isEmpty
                ? invite.address
                : invite.dnsName.components(separatedBy: ".").first ?? invite.address)
            let generated: (String, String)
            do { generated = try SSHKeys.generateGuestKey(name: keyName) } catch {
                DispatchQueue.main.async { completion(.failure(Failure.keygen)) }
                return
            }
            let (keyPath, publicKey) = generated
            let discard = {
                try? FileManager.default.removeItem(atPath: keyPath)
                try? FileManager.default.removeItem(atPath: keyPath + ".pub")
            }

            let body: [String: Any] = [
                "token": invite.token,
                "publicKey": publicKey,
                "name": Host.current().localizedName ?? "",
            ]
            // generous: the host has to notice the prompt and click Allow
            MiniHTTP.post(host: invite.address, port: invite.invitePort, path: "/shh/join",
                          json: body, timeout: 180) { result in
                switch result {
                case .failure(let e):
                    discard()
                    completion(.failure(e))
                case .success(let (status, json)):
                    guard status == 200 else {
                        discard()
                        completion(.failure(Failure.refused(
                            json["error"] as? String ?? "The other Mac refused (\(status)).")))
                        return
                    }
                    do {
                        completion(.success(try save(invite: invite, reply: json,
                                                     keyPath: keyPath)))
                    } catch {
                        discard()
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private static func save(invite: InviteCode, reply: [String: Any], keyPath: String) throws -> String {
        // The invite came over a channel the user trusts; the reply came over
        // the network. Only accept host keys the invite vouches for.
        let keys = (reply["hostKeys"] as? [String] ?? []).compactMap(SSHKeys.normalizePublicKey)
        guard keys.contains(where: { SSHKeys.fingerprint(ofPublicKey: $0) == invite.fingerprint })
        else { throw Failure.hostKeyMismatch }

        let host = invite.dnsName.isEmpty ? invite.address : invite.dnsName
        try SSHKeys.addKnownHosts(names: [host, invite.address].uniqued(), keys: keys)

        let user = (reply["user"] as? String).flatMap { Shell.isSafe($0) && !$0.isEmpty ? $0 : nil }
            ?? invite.user
        let port = (reply["sshPort"] as? Int).map(String.init) ?? "22"
        return AppModel.shared.saveServer(existing: nil, displayName: invite.hostLabel,
                                          slug: nil, host: host, user: user, port: port,
                                          auth: "key", secret: keyPath,
                                          icon: .symbol("laptopcomputer"))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
