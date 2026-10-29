import Foundation
import Security

/// Generic-password Keychain wrapper for the few secrets the app keeps: the Intervals credential and the LLM key.
struct KeychainStore {
    let service: String

    static let live = KeychainStore(service: "com.felipejaner.cadencia")

    func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func readString(_ account: String) -> String? {
        read(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func write(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func write(_ string: String, account: String) {
        write(Data(string.utf8), account: account)
    }

    func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func readCodable<T: Decodable>(_ type: T.Type, account: String) -> T? {
        read(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func writeCodable<T: Encodable>(_ value: T, account: String) {
        if let data = try? JSONEncoder().encode(value) { write(data, account: account) }
    }
}
