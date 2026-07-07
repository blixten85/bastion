import Foundation

/// En namngiven, sparad S3-anslutning — samma "wrapper runt ren
/// datamodell"-mönster som `WireGuardProfile` runt sin `config`. Nycklarna
/// sparas i klartext i JSON-filen, precis som `WireGuardProfile` redan gör
/// för WireGuard-privatnycklar (samma medvetna v1-avgränsning, ingen
/// Keychain-motsvarighet på Linux/Windows än).
public struct S3Connection: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var endpoint: String
    public var region: String
    public var accessKeyID: String
    public var secretAccessKey: String
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.region = region
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.modifiedAt = modifiedAt
    }

    public var credentials: S3Credentials {
        S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
    }

    public var endpointURL: URL? { URL(string: endpoint) }
}

/// Persistent S3-anslutningsdatabas (JSON på disk) — samma mönster som
/// `WireGuardProfileStore`/`SnippetStore`. Standardplats:
/// `~/.bastion/s3connections.json`. `path: nil` = endast i minne (test).
public final class S3ConnectionStore {
    private let path: String?
    private let lock = NSLock()
    private var byID: [UUID: S3Connection]

    public static var defaultPath: String {
        (("~/.bastion/s3connections.json") as NSString).expandingTildeInPath
    }

    public init(path: String? = S3ConnectionStore.defaultPath) {
        self.path = path
        self.byID = Dictionary(
            S3ConnectionStore.load(path: path).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func load(path: String?) -> [S3Connection] {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([S3Connection].self, from: data)) ?? []
    }

    public func all() -> [S3Connection] {
        lock.withLock { Array(byID.values) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func get(_ id: UUID) -> S3Connection? {
        lock.withLock { byID[id] }
    }

    public func upsert(_ connection: S3Connection) {
        lock.withLock {
            var c = connection
            c.modifiedAt = Date()
            byID[c.id] = c
            persist()
        }
    }

    public func delete(_ id: UUID) {
        lock.withLock {
            byID[id] = nil
            persist()
        }
    }

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
