import CryptoKit
import Foundation

/// The iPad's own SSH identity: an ed25519 keypair generated on device and
/// kept in the Keychain. The user appends the public half to
/// ~/.ssh/authorized_keys once; the private key never leaves the device and
/// there is nothing to paste or parse.
enum DeviceSSHKey {
    private static let account = "software.sister.codeserverclient.ssh-ed25519"

    /// Loads the device key, creating and persisting one on first use.
    static func privateKey() -> Curve25519.Signing.PrivateKey {
        if let data = readKeychain(), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        writeKeychain(key.rawRepresentation)
        return key
    }

    /// authorized_keys line: "ssh-ed25519 <base64 blob> Code-iPad".
    static func publicKeyOpenSSH() -> String {
        let publicKey = privateKey().publicKey.rawRepresentation

        var blob = Data()
        func append(_ data: Data) {
            var length = UInt32(data.count).bigEndian
            blob.append(Data(bytes: &length, count: 4))
            blob.append(data)
        }
        append(Data("ssh-ed25519".utf8))
        append(publicKey)

        return "ssh-ed25519 \(blob.base64EncodedString()) Code-iPad"
    }

    // MARK: - Keychain

    private static func readKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeKeychain(_ data: Data) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(attributes as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
