import Foundation

/// Ett namngivet, sparat `WireGuardConfig` — samma "wrapper runt ren
/// datamodell"-mönster som `Snippet` runt sin `template`.
public struct WireGuardProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var config: WireGuardConfig
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, config: WireGuardConfig, modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.config = config
        self.modifiedAt = modifiedAt
    }
}

/// Persistent WireGuard-profildatabas (JSON på disk) — samma mönster som
/// `SnippetStore`. Standardplats: `~/.bastion/wireguard.json`. `path: nil` =
/// endast i minne (test).
public final class WireGuardProfileStore {
    private let path: String?
    private let lock = NSLock()
    private var byID: [UUID: WireGuardProfile]

    public static var defaultPath: String {
        (("~/.bastion/wireguard.json") as NSString).expandingTildeInPath
    }

    public init(path: String? = WireGuardProfileStore.defaultPath) {
        self.path = path
        self.byID = Dictionary(
            WireGuardProfileStore.load(path: path).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func load(path: String?) -> [WireGuardProfile] {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([WireGuardProfile].self, from: data)) ?? []
    }

    /// Alla profiler, sorterade på namn (skiftlägesokänsligt).
    public func all() -> [WireGuardProfile] {
        lock.withLock { Array(byID.values) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func get(_ id: UUID) -> WireGuardProfile? {
        lock.withLock { byID[id] }
    }

    /// Lägg till eller uppdatera. Stämplar `modifiedAt = nu`.
    public func upsert(_ profile: WireGuardProfile) {
        lock.withLock {
            var p = profile
            p.modifiedAt = Date()
            byID[p.id] = p
            persist()
        }
    }

    public func delete(_ id: UUID) {
        lock.withLock {
            byID[id] = nil
            persist()
        }
    }

    // Anropas med låset hållet.
    private func persist() {
        guard let path else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Array(byID.values).sorted { $0.name < $1.name }) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
