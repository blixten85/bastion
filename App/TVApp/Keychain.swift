#if canImport(Security) && canImport(SwiftUI)
import Foundation
import Security

/// Minimal Keychain-wrapper för hemligheter (sync-lösenfras, ev. värdlösenord).
/// Värden lagras krypterade av systemet och lämnar aldrig enheten i klartext.
enum Keychain {
    // Utan en stabil kSecAttrService kan en generic-password-post med samma
    // "account"-sträng krocka med en post från en annan tjänst i samma app-
    // access-group och skriva över/radera fel post (cubic P2). Namnrymdar
    // alla tvOS-nycklar under den här appens eget bundle-ID.
    private static let service = "se.denied.bastion.tv.keychain"

    // Keychain-IPC kan blockera i värsta fall (systemet, delad enhet under
    // belastning) — en serialiserad bakgrundskö låter UI-anropare `await`a
    // resultatet istället för att blockera main-actor-tråden rakt av
    // (cubic P3, se `setAsync`/`getAsync`/`deleteAsync` nedan).
    private static let queue = DispatchQueue(label: "se.denied.bastion.tv.keychain.queue")

    static func setAsync(_ value: String, for key: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: set(value, for: key)) }
        }
    }

    static func getAsync(_ key: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: get(key)) }
        }
    }

    /// Skiljer "posten finns inte" från "läsningen misslyckades" — `get`
    /// ovan mappar båda till `nil`, vilket lät ett TRANSIENT Keychain-fel
    /// se ut som "ingen sparad hemlighet" för anropare som behöver agera
    /// annorlunda på faktiskt fel (t.ex. inte tolka det som "användaren
    /// har ingen lösenfras" och radera en post som aldrig faktiskt lästes,
    /// cubic P1).
    enum ReadResult {
        case found(String)
        case notFound
        case failed
    }

    static func getResultAsync(_ key: String) async -> ReadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: key,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    guard let data = result as? Data else {
                        continuation.resume(returning: .failed)
                        return
                    }
                    continuation.resume(returning: .found(String(decoding: data, as: UTF8.self)))
                case errSecItemNotFound:
                    continuation.resume(returning: .notFound)
                default:
                    continuation.resume(returning: .failed)
                }
            }
        }
    }

    static func deleteAsync(_ key: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: delete(key)) }
        }
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        // En konkurrerande `set`-anrop kan ha lagt till posten mellan vårt
        // `errSecItemNotFound`-svar ovan och det här `SecItemAdd` — det
        // syns här som `errSecDuplicateItem`, inte ett riktigt fel (cubic
        // P2). Uppdatera på plats istället för att rapportera falskt
        // misslyckande.
        guard addStatus == errSecDuplicateItem else { return false }
        return SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // "Fanns redan inte" räknas som lyckat — anroparen ville att posten
        // inte längre finns, och det stämmer redan (cubic P1: en anropare
        // som särskiljer misslyckande här måste kunna skilja en RIKTIG
        // Keychain-läsfel från "inget att radera").
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
#endif
