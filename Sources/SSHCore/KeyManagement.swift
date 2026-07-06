import Crypto
import Foundation
import NIOSSH

/// Ett nygenererat Ed25519-nyckelpar: fröet (för `SSHAuth.ed25519Seed`/Keychain-
/// lagring) och den publika raden i OpenSSH-format (för `authorized_keys`/export).
public struct GeneratedKeyPair: Sendable {
    public let seed: Data
    public let publicKeyLine: String
}

public enum KeyGenerator {
    /// Genererar ett helt nytt, slumpmässigt Ed25519-nyckelpar. `comment`
    /// bifogas den publika raden (samma konvention som `ssh-keygen -C`) —
    /// rent kosmetiskt, ingen del av själva nyckelmaterialet.
    public static func generateEd25519(comment: String = "") -> GeneratedKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nioKey = NIOSSHPrivateKey(ed25519Key: privateKey)
        var line = String(openSSHPublicKey: nioKey.publicKey)
        if !comment.isEmpty { line += " " + comment }
        return GeneratedKeyPair(seed: privateKey.rawRepresentation, publicKeyLine: line)
    }
}

/// Escapar en sträng säkert för inbäddning i ETT enkelcitat POSIX shell-
/// argument: avsluta citatet, lägg till en escapad enkelcitation, öppna
/// citatet igen (`'` -> `'\''`). Nödvändigt eftersom en nyckelkommentar är
/// fri text från användaren, inte ett validerbart smalt format (till skillnad
/// från `DockerService.validate`s namn-allowlist).
func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Bygger kommandot som lägger till `publicKeyLine` i `~/.ssh/authorized_keys`
/// — idempotent (kör om säkert, aldrig dubblettrader), skapar `~/.ssh` med
/// rätt rättigheter (700/600) om den saknas. Egen funktion (inte inline i
/// `deployPublicKey`) just för att kunna testa den exakta kommandosträngen
/// utan en riktig SSH-anslutning.
func deployPublicKeyCommand(_ publicKeyLine: String) -> String {
    let quoted = shellQuoted(publicKeyLine)
    return """
    mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && \
    chmod 600 ~/.ssh/authorized_keys && \
    (grep -qxF \(quoted) ~/.ssh/authorized_keys || echo \(quoted) >> ~/.ssh/authorized_keys)
    """
}

extension SSHSession {
    /// Lägger till en publik nyckel i fjärrsidans `~/.ssh/authorized_keys`.
    /// Kräver en redan autentiserad session (vilken auth-metod som helst —
    /// det är separat från den nya nyckeln som deployas).
    public func deployPublicKey(_ publicKeyLine: String) async throws {
        for try await _ in execute(deployPublicKeyCommand(publicKeyLine)) {}
    }

    /// Öppnar en TYST, separat anslutning mot samma mål med den angivna
    /// nyckeln och kontrollerar att autentiseringen faktiskt lyckas — utan
    /// att köra något kommando eller lämna sessionen öppen. Används för att
    /// bevisa att en nyss deployad nyckel verkligen fungerar INNAN ett
    /// lösenord tas bort ur Bastions egen lagring för host-profilen.
    public static func verifyKeyAuthWorks(target: SSHTarget, seed: Data, knownHosts: KnownHosts) async -> Bool {
        let probe = SSHSession(target: target, auth: .ed25519Seed(seed), knownHosts: knownHosts)
        do {
            try await probe.connect()
            await probe.close()
            return true
        } catch {
            await probe.close()
            return false
        }
    }
}
