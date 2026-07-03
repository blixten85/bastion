import Foundation

/// En synktransport: hämta fjärrtillstånd och skriv tillbaka det sammanslagna.
/// Medvetet minimal så olika ryggar kan implementeras — iCloud Drive, Dropbox,
/// Syncthing, en Git-mapp, WebDAV — utan att kärnan bryr sig om vilken.
public protocol SyncProvider: Sendable {
    func pull() throws -> SyncState?
    func push(_ state: SyncState) throws
}

/// Enklaste transporten: en JSON-fil i en mapp som något annat synkar mellan
/// enheter (iCloud Drive-behållare, Dropbox, Syncthing, en klonad Git-mapp …).
/// Ingen inloggning, ingen server — bara en fil.
public struct FolderSyncProvider: SyncProvider {
    private let path: String

    public init(path: String) {
        self.path = (path as NSString).expandingTildeInPath
    }

    public func pull() throws -> SyncState? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(SyncState.self, from: data)
    }

    public func push(_ state: SyncState) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: URL(fileURLWithPath: path))
    }
}
