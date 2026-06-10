import Foundation
import NIOSSH

/// Trust-on-first-use host key pinning: the first key a host presents is
/// stored (OpenSSH string form, UserDefaults); later connections must present
/// the same key or fail loudly. Re-saving the SSH target forgets its pin.
enum HostKeyStore {
    private static func key(host: String, port: Int) -> String {
        "ssh-hostkey:\(host):\(port)"
    }

    static func stored(host: String, port: Int) -> String? {
        UserDefaults.standard.string(forKey: key(host: host, port: port))
    }

    static func store(_ openSSHKey: String, host: String, port: Int) {
        UserDefaults.standard.set(openSSHKey, forKey: key(host: host, port: port))
    }

    static func forget(host: String, port: Int) {
        UserDefaults.standard.removeObject(forKey: key(host: host, port: port))
    }
}
