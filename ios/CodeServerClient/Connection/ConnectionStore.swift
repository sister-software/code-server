import Foundation

/// Minimal persistence for v1: just the server URL. Login itself is handled by
/// code-server's own web login page; the session cookie lives in the persistent
/// WKWebsiteDataStore, so it survives relaunches.
enum ConnectionStore {
    private static let urlKey = "serverURL"

    /// Pre-filled default so the app connects out of the box. Overridden once the
    /// user saves a URL in the connection editor.
    private static let defaultURL = URL(string: "https://code.sister.software")

    static var serverURL: URL? {
        get {
            if let string = UserDefaults.standard.string(forKey: urlKey) {
                return URL(string: string)
            }
            return defaultURL
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: urlKey)
        }
    }
}
