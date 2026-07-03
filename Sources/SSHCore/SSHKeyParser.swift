import Foundation

public enum SSHKeyError: Error, Sendable {
    case notOpenSSHFormat
    case unsupportedKeyType(String)
    case encrypted          // lösenfras-skyddad — stöds inte än
    case malformed
}

/// Läser en privatnyckel i OpenSSH-format (`-----BEGIN OPENSSH PRIVATE KEY-----`),
/// den standard `ssh-keygen` skapar. Stöder okrypterade Ed25519-nycklar och
/// returnerar auth-metoden direkt. Krypterade nycklar (lösenfras) samt RSA/ECDSA
/// är nästa steg — vi kastar tydligt fel i stället för att gissa.
public enum OpenSSHPrivateKey {
    public static func parse(_ pem: String) throws -> SSHAuth {
        let body = pem
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw SSHKeyError.notOpenSSHFormat }

        var r = ByteReader(data)
        guard (try? r.expect(Array("openssh-key-v1".utf8) + [0])) != nil else {
            throw SSHKeyError.notOpenSSHFormat
        }
        let cipher = try r.readStringUTF8()
        let kdf = try r.readStringUTF8()
        _ = try r.readString()            // kdfoptions
        guard try r.readU32() == 1 else { throw SSHKeyError.malformed }
        _ = try r.readString()            // publik nyckel

        let privSection = try r.readString()
        guard cipher == "none", kdf == "none" else { throw SSHKeyError.encrypted }

        var pr = ByteReader(Data(privSection))
        let check1 = try pr.readU32()
        let check2 = try pr.readU32()
        guard check1 == check2 else { throw SSHKeyError.malformed }   // fel lösenfras/korrupt

        let keyType = try pr.readStringUTF8()
        guard keyType == "ssh-ed25519" else { throw SSHKeyError.unsupportedKeyType(keyType) }

        _ = try pr.readString()           // publik nyckel (32 byte)
        let secret = try pr.readString()  // 64 byte: frö(32) || publik(32)
        guard secret.count == 64 else { throw SSHKeyError.malformed }
        return .ed25519Seed(Data(secret.prefix(32)))
    }

    /// Läser och parsar en nyckelfil från disk.
    public static func load(path: String) throws -> SSHAuth {
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(pem)
    }
}

/// Minimal läsare för SSH:s binära wire-format (uint32-längd + bytes, big-endian).
private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ data: Data) { bytes = Array(data) }

    mutating func readU32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw SSHKeyError.malformed }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= bytes.count else { throw SSHKeyError.malformed }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    mutating func readString() throws -> [UInt8] {
        try readBytes(Int(try readU32()))
    }

    mutating func readStringUTF8() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    mutating func expect(_ magic: [UInt8]) throws {
        guard try readBytes(magic.count) == magic else { throw SSHKeyError.notOpenSSHFormat }
    }
}
