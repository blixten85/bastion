#if canImport(SwiftUI)
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Delade hjälpare för att välja filer/mappar via systemets dokumentväljare.
/// iOS-appen är sandlådad: användaren kan inte skriva in en sökväg till
/// `~/.ssh/…` eller en molnmapp — filer måste PLOCKAS via `.fileImporter`, och
/// för mappar sparas ett security-scoped bookmark så åtkomsten överlever
/// omstarter.
enum FileImport {
    /// Innehållstyper vi tillåter för nyckel-/config-filer. `.item` släpper
    /// igenom utökningslösa filer (t.ex. `id_ed25519`, `config`) som annars
    /// typas som `public.data` och inte matchar `.plainText`.
    static let textLike: [UTType] = [.plainText, .text, .data, .item]

    /// Läser textinnehållet ur en fil vald via `.fileImporter`. Hanterar
    /// security-scoped åtkomst. Returnerar nil vid avbrott/läsfel.
    static func readText(from result: Result<[URL], Error>) -> String? {
        guard case .success(let urls) = result, let url = urls.first else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}

/// Security-scoped bookmark till synkmappen (iCloud Drive / Files-appen /
/// valfri molnmapp). En sandlådad iOS-app får bara nå en användarvald mapp så
/// länge den håller ett bookmark och öppnar security-scoped åtkomst runt varje
/// I/O — därför räckte det gamla, fritt inskrivna sökvägsfältet aldrig.
enum SyncFolder {
    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Sparar ett bookmark till den valda mappen + ett visningsnamn. Returnerar
    /// visningsnamnet (sista sökvägskomponenten) vid framgång.
    @discardableResult
    static func save(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(
            options: createOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        UserDefaults.standard.set(data, forKey: SyncKeys.folderBookmark)
        UserDefaults.standard.set(url.lastPathComponent, forKey: SyncKeys.folderPath)
        return url.lastPathComponent
    }

    /// Resolvar bookmarket till en URL. Uppdaterar bookmarket om det blivit
    /// inaktuellt (staleness) så åtkomsten inte tappas över tid. Anroparen
    /// ansvarar för `startAccessingSecurityScopedResource()` runt sin I/O.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: SyncKeys.folderBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolveOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: SyncKeys.folderBookmark)
            UserDefaults.standard.removeObject(forKey: SyncKeys.folderPath)
            return nil
        }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(
                options: createOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: SyncKeys.folderBookmark)
            }
        }
        return url
    }
}
#endif
