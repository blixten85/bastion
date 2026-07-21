#if canImport(Security) && canImport(SwiftUI)
import Foundation
import Security

/// Minimal Keychain-wrapper för hemligheter (sync-lösenfras, ev. värdlösenord).
/// Värden lagras krypterade av systemet och lämnar aldrig enheten i klartext.
enum Keychain {
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        // Uppdatera på plats om posten redan finns istället för
        // delete-så-add — den gamla ordningen kunde permanent radera en
        // fungerande hemlighet (t.ex. synk-lösenfrasen) om `SecItemAdd`
        // misslyckades EFTER att `SecItemDelete` redan tagit bort den gamla
        // posten (cubic P2). `SecItemUpdate` byter aldrig ut posten förrän
        // den nya datan är skriven.
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
#endif
