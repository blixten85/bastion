import Foundation

/// Hur en sparad värd autentiseras. Hemligheter lagras INTE här — lösenord hör
/// hemma i Keychain (iOS/macOS), och `keyFile` pekar bara på en nyckel på disk.
public enum HostAuth: Codable, Sendable, Equatable {
    case askPassword            // fråga vid varje anslutning (ev. via Keychain)
    case keyFile(String)        // sökväg till en (okrypterad) privatnyckel
    case agentDefault           // ~/.ssh/id_ed25519 / ssh-config
    case keychainKey(String)    // nyckelmaterial importerat i appen, id i Keychain
}

/// En sparad värd i host-databasen. Ren metadata (inga hemligheter) så den kan
/// synkas och säkerhetskopieras fritt. Taggar i stället för enbart mappar.
public struct Host: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var alias: String
    public var hostName: String
    public var user: String
    public var port: Int
    public var tags: [String]
    public var auth: HostAuth
    /// När värden senast ändrades. Styr sync-mergen (nyaste ändringen vinner).
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        alias: String,
        hostName: String,
        user: String,
        port: Int = 22,
        tags: [String] = [],
        auth: HostAuth = .agentDefault,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.tags = tags
        self.auth = auth
        self.modifiedAt = modifiedAt
    }

    /// Anslutningsmål för `SSHSession`.
    public var target: SSHTarget {
        SSHTarget(host: hostName, port: port, username: user)
    }

    /// Bygger värdar ur en `~/.ssh/config`. Varje konkret `Host`-alias blir en
    /// post med upplösta HostName/User/Port/IdentityFile. Alias utan användare
    /// hoppas över (kan inte anslutas ändå).
    public static func imported(from config: SSHConfig) -> [Host] {
        config.hostAliases.compactMap { alias in
            let r = config.resolve(alias)
            guard let user = r.user, !user.isEmpty else { return nil }
            let auth: HostAuth = r.identityFile.map { .keyFile($0) } ?? .agentDefault
            return Host(alias: alias, hostName: r.hostName, user: user, port: r.port, auth: auth)
        }
    }
}
