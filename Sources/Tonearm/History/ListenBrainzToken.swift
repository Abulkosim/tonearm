import Foundation
import Security

/// Where the ListenBrainz token is kept.
protocol LBTokenStore: AnyObject {
    func read() -> String?
    func write(_ token: String) throws
    func delete()
}

/// The token in the login Keychain, as a generic password. Never in UserDefaults or a file.
final class KeychainTokenStore: LBTokenStore {
    let service: String
    let account: String
    /// Read once, so sending does not ask the Keychain every time.
    private var cached: String??
    private let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus

    init(service: String = "io.github.abulkosim.tonearm.listenbrainz", account: String = "token",
         copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = {
             SecItemCopyMatching($0, $1)
         }) {
        self.service = service
        self.account = account
        self.copyMatching = copyMatching
    }

    struct KeychainError: Error, CustomStringConvertible {
        var status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        if let cached { return cached }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = copyMatching(q as CFDictionary, &item)
        let token = status == errSecSuccess ? (item as? Data).map { String(decoding: $0, as: UTF8.self) } : nil
        // Every answer is remembered until the token is written or deleted, so a "Deny" is
        // not asked again on each song. Only a locked Keychain, which shows no prompt, is
        // asked again next time.
        if status != errSecInteractionNotAllowed { cached = .some(token) }
        return token
    }

    func write(_ token: String) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Tonearm ListenBrainz token"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        cached = .some(token)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
        cached = .some(nil)
    }
}

/// For tests and snapshots.
final class MemoryTokenStore: LBTokenStore {
    var token: String?
    init(_ token: String? = nil) { self.token = token }
    func read() -> String? { token }
    func write(_ token: String) throws { self.token = token }
    func delete() { token = nil }
}
