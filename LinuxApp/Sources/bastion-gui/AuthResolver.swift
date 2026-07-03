import Foundation
import SSHCore

/// `Foundation.Host` finns även på Linux och krockar annars med `SSHCore.Host`
/// — samma fix som `App/Platform.swift` gör för iOS/macOS.
typealias Host = SSHCore.Host

/// Bygger `SSHAuth` för en värd. Samma logik som `App/AuthResolver.swift`,
/// men utan Keychain — Linux/Windows saknar en motsvarighet ännu.
func resolveAuth(for host: Host, password: String?) -> SSHAuth? {
    switch host.auth {
    case .askPassword:
        return password.map { SSHAuth.password($0) }
    case .keyFile(let path):
        return try? OpenSSHPrivateKey.load(path: path)
    case .agentDefault:
        let def = ("~/.ssh/id_ed25519" as NSString).expandingTildeInPath
        return try? OpenSSHPrivateKey.load(path: def)
    case .keychainKey:
        // Importerade nycklar lagras i Apples Keychain (se App/Keychain.swift) —
        // inget motsvarande säkert nyckelvalv finns här än. Använd Nyckelfil
        // (sökväg) eller standardnyckel/agent på Linux/Windows tills vidare.
        return nil
    }
}
