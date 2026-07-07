import Crypto
import Foundation

/// Parsning + CA-signaturverifiering av OpenSSH-certifikat
/// (`ssh-ed25519-cert-v01@openssh.com`) — de stora molnleverantörernas
/// SSH-autentiseringsmodell (identitetsleverantör utfärdar ett kortlivat
/// certifikat efter inloggning, istället för en statisk nyckel: Cloudflare
/// Access, Google Cloud OS Login, Microsoft Entra ID, se ROADMAP.md).
/// v1: parsning + `verifySignature()` (se den för vad som verifieras och
/// INTE verifieras — giltighetsperiod/principals är anroparens ansvar).
/// INTE `SSHUserAuth`-wiring (att faktiskt använda ett cert för att logga
/// in) än — det är nästa, separata steg, se ROADMAP.
///
/// Trådformatet verifierat mot OpenSSHs egen `PROTOCOL.certkeys`-
/// specifikation OCH empiriskt mot ett riktigt certifikat genererat med
/// `ssh-keygen -s` (avkodat byte-för-byte, jämfört mot `ssh-keygen -L`s
/// tolkning) — inte gissat ur minnet. Bara Ed25519 stöds (matchar
/// resten av kodbasens nuvarande begränsning, se `SSHKeyError.unsupportedKeyType`).
public struct OpenSSHCertificate: Sendable, Equatable {
    public enum CertType: UInt32, Sendable, Equatable {
        case user = 1
        case host = 2
    }

    public struct CriticalOption: Sendable, Equatable {
        public let name: String
        /// Rådata för optionen. För `force-command`/`source-address` är
        /// detta i sin tur en nästlad SSH-sträng (uint32-längd + bytes) —
        /// bekräftat genom att avkoda ett riktigt genererat certifikat
        /// byte-för-byte, inte antaget ur specen. `decodedString` avkodar
        /// den nästlingen; `nil` om `data` inte är en giltig nästlad sträng.
        public let data: Data

        public var decodedString: String? {
            var reader = CertByteReader(data)
            guard let bytes = try? reader.readString(), reader.isAtEnd else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    public let nonce: Data
    public let publicKey: Data
    public let serial: UInt64
    public let type: CertType
    public let keyID: String
    public let validPrincipals: [String]
    public let validAfter: Date
    public let validBefore: Date
    public let criticalOptions: [CriticalOption]
    /// Namnen på satta extensions (`permit-pty` osv.) — deras data-fält är
    /// enligt specen alltid tomt (rena flaggor), så bara namnet är av intresse.
    public let extensionNames: [String]
    /// Rå nyckel-blob för den signerande CA:n (t.ex. `ssh-ed25519` +
    /// 32-byte publik nyckel) — inte avkodad till en specifik nyckeltyp
    /// eftersom CA:n kan vara RSA/ECDSA även om det signerade certifikatet
    /// är Ed25519.
    public let signatureKeyBlob: Data
    public let signatureBlob: Data
    /// Exakt de råa bytesen som CA:n signerade — enligt `PROTOCOL.certkeys`
    /// är det "hela certifikatet, fram till men inte inklusive signaturen"
    /// (dvs. magic...signatureKeyBlob, men INTE signatureBlob-fältet).
    /// Sparas som en slice av ORIGINALBLOBET vid parsning, inte
    /// återkonstruerad ur avkodade fält — en återkonstruktion riskerar
    /// subtila kodningsskillnader (t.ex. fältordning) som skulle göra
    /// signaturverifieringen falskt negativ (eller, värre, falskt positiv
    /// om återkonstruktionen råkar vara "nästan rätt"). Se `verifySignature()`.
    public let signedData: Data

    public static let magic = "ssh-ed25519-cert-v01@openssh.com"

    /// Parsar en publik-nyckel-rad (`ssh-ed25519-cert-v01@openssh.com AAAA... kommentar`)
    /// eller bara den råa base64-delen.
    public static func parse(_ line: String) throws -> OpenSSHCertificate {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let base64Part = parts.count >= 2 ? parts[1] : parts.first else {
            throw SSHKeyError.malformed
        }
        guard let blob = Data(base64Encoded: String(base64Part)) else {
            throw SSHKeyError.malformed
        }
        return try parse(blob: blob)
    }

    static func parse(blob: Data) throws -> OpenSSHCertificate {
        var reader = CertByteReader(blob)
        let magicRead = String(decoding: try reader.readString(), as: UTF8.self)
        guard magicRead == magic else { throw SSHKeyError.unsupportedKeyType(magicRead) }

        let nonce = Data(try reader.readString())
        let publicKey = Data(try reader.readString())
        let serial = try reader.readU64()
        guard let type = CertType(rawValue: try reader.readU32()) else {
            throw SSHKeyError.malformed
        }
        let keyID = String(decoding: try reader.readString(), as: UTF8.self)

        var principals: [String] = []
        var principalsReader = CertByteReader(Data(try reader.readString()))
        while !principalsReader.isAtEnd {
            principals.append(String(decoding: try principalsReader.readString(), as: UTF8.self))
        }

        let validAfter = Date(timeIntervalSince1970: TimeInterval(try reader.readU64()))
        let validBefore = Date(timeIntervalSince1970: TimeInterval(try reader.readU64()))

        var criticalOptions: [CriticalOption] = []
        var criticalOptionsReader = CertByteReader(Data(try reader.readString()))
        while !criticalOptionsReader.isAtEnd {
            let name = String(decoding: try criticalOptionsReader.readString(), as: UTF8.self)
            let data = Data(try criticalOptionsReader.readString())
            criticalOptions.append(CriticalOption(name: name, data: data))
        }

        var extensionNames: [String] = []
        var extensionsReader = CertByteReader(Data(try reader.readString()))
        while !extensionsReader.isAtEnd {
            extensionNames.append(String(decoding: try extensionsReader.readString(), as: UTF8.self))
            _ = try extensionsReader.readString()  // datafält, alltid tomt enligt specen — läses ändå av för att hålla positionen synkad
        }

        _ = try reader.readString()  // reserved
        let signatureKeyBlob = Data(try reader.readString())
        let signedDataLength = reader.offset  // precis EFTER signatureKeyBlob, precis FÖRE signatureBlob
        let signatureBlob = Data(try reader.readString())
        let signedData = blob.prefix(signedDataLength)

        return OpenSSHCertificate(
            nonce: nonce, publicKey: publicKey, serial: serial, type: type, keyID: keyID,
            validPrincipals: principals, validAfter: validAfter, validBefore: validBefore,
            criticalOptions: criticalOptions, extensionNames: extensionNames,
            signatureKeyBlob: signatureKeyBlob, signatureBlob: signatureBlob, signedData: signedData)
    }

    /// Verifierar CA-signaturen — bekräftar att en CA som äger
    /// `signatureKeyBlob`s privata nyckel verkligen signerat EXAKT det här
    /// certifikatets innehåll (avslöjar manipulation/förfalskning).
    /// Verifierar INTE giltighetsperiod, principals eller critical options
    /// — bara den kryptografiska signaturen. Anroparen ansvarar för
    /// resten av trust-beslutet (giltighetsfönster, vilken CA som litas på).
    ///
    /// Bara CA:er som signerar med `ssh-ed25519` stöds (matchar resten av
    /// kodbasens Ed25519-avgränsning, se `SSHKeyError.unsupportedKeyType`) —
    /// RSA/ECDSA-signerande CA:er kastar tydligt istället för att gissa.
    public func verifySignature() throws -> Bool {
        var keyReader = CertByteReader(signatureKeyBlob)
        let signingKeyType = String(decoding: try keyReader.readString(), as: UTF8.self)
        guard signingKeyType == "ssh-ed25519" else {
            throw OpenSSHCertificateError.unsupportedSigningKeyType(signingKeyType)
        }
        let rawSigningKey = try keyReader.readString()
        guard rawSigningKey.count == 32 else { throw OpenSSHCertificateError.malformedSignature }
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(rawSigningKey))

        var sigReader = CertByteReader(signatureBlob)
        let signatureType = String(decoding: try sigReader.readString(), as: UTF8.self)
        guard signatureType == "ssh-ed25519" else {
            throw OpenSSHCertificateError.unsupportedSigningKeyType(signatureType)
        }
        let rawSignature = try sigReader.readString()
        guard rawSignature.count == 64 else { throw OpenSSHCertificateError.malformedSignature }

        return signingKey.isValidSignature(Data(rawSignature), for: signedData)
    }
}

public enum OpenSSHCertificateError: Error, Sendable, Equatable {
    /// CA:ns signeringsnyckeltyp (eller signaturens egen typ) är inte
    /// `ssh-ed25519` — t.ex. en RSA- eller ECDSA-signerande CA.
    case unsupportedSigningKeyType(String)
    /// Signaturblobben eller CA-nyckelblobben hade fel längd för sin
    /// deklarerade typ (t.ex. inte 32/64 byte för ssh-ed25519).
    case malformedSignature
}

/// Samma SSH-trådformat (uint32-längd-prefixade strängar, big-endian) som
/// `SSHKeyParser.swift`s `ByteReader`, plus `readU64` (behövs för
/// serial/valid-after/valid-before, som `ByteReader` inte hade användning
/// för tidigare) — en egen, fil-lokal kopia snarare än att göra den delade
/// privata typen internal, samma mönster som SFTPProtocol.swift redan har
/// sin egen ramningskod separat från SSHKeyParser.swift.
private struct CertByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0
    init(_ data: Data) { bytes = Array(data) }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readU32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw SSHKeyError.malformed }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    mutating func readU64() throws -> UInt64 {
        let high = try readU32()
        let low = try readU32()
        return (UInt64(high) << 32) | UInt64(low)
    }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= bytes.count else { throw SSHKeyError.malformed }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    mutating func readString() throws -> [UInt8] {
        try readBytes(Int(try readU32()))
    }
}
