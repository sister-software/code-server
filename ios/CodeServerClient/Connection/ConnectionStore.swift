import Foundation

/// Persists the list of known code-server instances and which one is current.
/// Login itself is handled by code-server's own web login page; the session
/// cookie lives in the persistent WKWebsiteDataStore, so it survives relaunches.
enum ConnectionStore {
    private static let serversKey = "servers"
    private static let currentKey = "currentServer"

    /// Seed so the app connects out of the box.
    private static let defaultURL = URL(string: "https://code.sister.software")!

    /// Known servers, most-recently-used first. Always non-empty (falls back to
    /// the seed) so the app always has somewhere to connect.
    static var servers: [URL] {
        get {
            let urls = (UserDefaults.standard.stringArray(forKey: serversKey) ?? [])
                .compactMap(URL.init(string:))
            return urls.isEmpty ? [defaultURL] : urls
        }
        set {
            UserDefaults.standard.set(newValue.map(\.absoluteString), forKey: serversKey)
        }
    }

    /// The server to load. Never nil — defaults to the most-recent / seed.
    static var serverURL: URL? {
        if let string = UserDefaults.standard.string(forKey: currentKey),
           let url = URL(string: string) {
            return url
        }
        return servers.first
    }

    /// Add (or promote) a server and make it current.
    static func use(_ url: URL) {
        var list = servers.filter { $0 != url }
        list.insert(url, at: 0)
        servers = list
        UserDefaults.standard.set(url.absoluteString, forKey: currentKey)
    }

    static func remove(_ url: URL) {
        let list = servers.filter { $0 != url }
        servers = list
        if serverURL == url {
            UserDefaults.standard.set(list.first?.absoluteString, forKey: currentKey)
        }
    }

    // MARK: - SSH remote target

    private static let sshTargetKey = "sshTarget"
    private static let sshNameKey = "sshName"

    /// "user@host[:port]" for the SSH remote, or nil if not configured.
    static var sshTarget: String? {
        get { UserDefaults.standard.string(forKey: sshTargetKey) }
        set { UserDefaults.standard.set(newValue, forKey: sshTargetKey) }
    }

    /// Friendly display name for the SSH remote (optional).
    static var sshName: String? {
        get { UserDefaults.standard.string(forKey: sshNameKey) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set((trimmed?.isEmpty ?? true) ? nil : trimmed, forKey: sshNameKey)
        }
    }

    /// Parses "user@host[:port]".
    static func parseSSHTarget(_ target: String) -> (user: String, host: String, port: Int)? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return nil }
        let user = String(trimmed[..<at])
        var host = String(trimmed[trimmed.index(after: at)...])
        var port = 22
        if let colon = host.lastIndex(of: ":"), let parsed = Int(host[host.index(after: colon)...]) {
            port = parsed
            host = String(host[..<colon])
        }
        guard !host.isEmpty else { return nil }
        return (user, host, port)
    }

    /// Normalize user input: accept bare hosts by defaulting to https.
    static func normalize(_ input: String) -> URL? {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string), url.host != nil,
              url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        return url
    }
}
