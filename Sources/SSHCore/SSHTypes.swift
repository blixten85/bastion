import Foundation

/// Vart vi ansluter.
public struct SSHTarget: Sendable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

/// Autentiseringsmetod. Lösenord är fullt implementerat. Publik nyckel stöds
/// för råa Ed25519-frön (32 byte) — OpenSSH-filparsning (`~/.ssh/id_ed25519`)
/// är nästa steg, se `SSHUserAuth`.
public enum SSHAuth: Sendable {
    case password(String)
    case ed25519Seed(Data)
    /// OpenSSH-certifikatautentisering: signerar med den råa Ed25519-fröet
    /// (`seed`, samma som `.ed25519Seed`) men erbjuder servern CERTIFIKATET
    /// (`certificateLine`, en hel `type base64 kommentar`-rad som en
    /// `-cert.pub`-fil) som "publik nyckel" istället för den bara nyckeln —
    /// servern validerar CA-signaturen + giltighet (se `SSHUserAuth.swift`).
    case certificate(seed: Data, certificateLine: String)
}

/// En bit utdata från fjärrkommandot.
public struct SSHChunk: Sendable {
    public enum Stream: Sendable { case stdout, stderr }
    public let stream: Stream
    public let bytes: [UInt8]

    public var text: String { String(decoding: bytes, as: UTF8.self) }
}

/// Värdnyckel-fingeravtryck som vi sett vid anslutning (TOFU-underlag för UI:t).
public struct HostKeyInfo: Sendable {
    public let sha256Fingerprint: String
    public let keyType: String
}

public enum SSHError: Error, Sendable {
    case connectionFailed(String)
    case authenticationFailed
    case channelFailed(String)
    case hostKeyRejected(HostKeyInfo)
    case remoteExit(status: Int)
}
