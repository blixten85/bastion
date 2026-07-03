import Foundation
import SSHCore

// bastion-cli — bevisar SSH-kärnan mot en riktig server.
//
//   bastion-cli <user@host[:port]> "<kommando>"
//
// Lösenord läses från miljövariabeln BASTION_PASSWORD (annars frågas det via
// stdin). Ed25519-nyckel (rått 32-byte frö, hex) kan ges via BASTION_ED25519_HEX.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    fail("Användning: bastion-cli <[user@]host-eller-alias[:port]> \"<kommando>\"")
}

// Destinationen kan vara user@host:port ELLER ett alias ur ~/.ssh/config.
// Uttryckliga delar (user, port) vinner över configen.
let dest = args[0]
var explicitUser: String?
var token = dest
if let atIdx = dest.firstIndex(of: "@") {
    explicitUser = String(dest[dest.startIndex..<atIdx])
    token = String(dest[dest.index(after: atIdx)...])
}
var explicitPort: Int?
if let colon = token.lastIndex(of: ":"), let p = Int(token[token.index(after: colon)...]) {
    explicitPort = p
    token = String(token[token.startIndex..<colon])
}

let cfg = SSHConfig.load().resolve(token)
let hostPart = cfg.hostName
let port = explicitPort ?? cfg.port
guard let username = explicitUser ?? cfg.user else {
    fail("Ingen användare: ange user@host eller sätt User för \(token) i ~/.ssh/config")
}
let command = args[1]

// Autentisering. Ordning: uttrycklig nyckelfil > rått frö > lösenord >
// IdentityFile ur ssh-config > standardnyckel (~/.ssh/id_ed25519) > lösenordsfråga.
let env = ProcessInfo.processInfo.environment
let auth: SSHAuth
func loadKey(_ path: String) -> SSHAuth {
    do { return try OpenSSHPrivateKey.load(path: path) }
    catch SSHKeyError.encrypted { fail("Nyckeln \(path) är lösenfras-skyddad — stöds inte än.") }
    catch SSHKeyError.unsupportedKeyType(let t) { fail("Nyckeltypen \(t) stöds inte än (endast Ed25519).") }
    catch { fail("Kunde inte läsa nyckeln \(path): \(error)") }
}

let defaultKey = ("~/.ssh/id_ed25519" as NSString).expandingTildeInPath
if let keyFile = env["BASTION_KEY_FILE"] {
    auth = loadKey(keyFile)
} else if let hex = env["BASTION_ED25519_HEX"], let seed = Data(hexString: hex) {
    auth = .ed25519Seed(seed)
} else if let pw = env["BASTION_PASSWORD"] {
    auth = .password(pw)
} else if let idf = cfg.identityFile, FileManager.default.fileExists(atPath: idf) {
    FileHandle.standardError.write(Data("Använder \(idf) (ssh-config)\n".utf8))
    auth = loadKey(idf)
} else if FileManager.default.fileExists(atPath: defaultKey) {
    FileHandle.standardError.write(Data("Använder \(defaultKey)\n".utf8))
    auth = loadKey(defaultKey)
} else {
    FileHandle.standardError.write(Data("Lösenord för \(username)@\(hostPart): ".utf8))
    guard let line = readLine(strippingNewline: true) else { fail("Inget lösenord.") }
    auth = .password(line)
}

let target = SSHTarget(host: hostPart, port: port, username: username)
let session = SSHSession(target: target, auth: auth)

do {
    try await session.connect()
    for try await chunk in session.execute(command) {
        let handle = chunk.stream == .stderr ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data(chunk.bytes))
    }
    await session.close()
} catch let SSHError.remoteExit(status) {
    await session.close()
    exit(Int32(status))
} catch let SSHError.hostKeyRejected(info) {
    await session.close()
    fail("""
    ⚠️  VÄRDNYCKELN HAR ÄNDRATS för \(hostPart):\(port)!
        Presenterad nyckel: \(info.keyType) \(info.sha256Fingerprint)
        Det kan vara en man-in-the-middle-attack — eller så har servern byggts om.
        Litar du på ändringen: ta bort raden för \(hostPart):\(port) ur
        \(KnownHosts.defaultPath) och anslut igen.
    """)
} catch {
    await session.close()
    fail("Fel: \(error)")
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = Data(bytes)
    }
}
