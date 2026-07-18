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
    case .certificateFile(let keyPath, let certPath):
        return try? OpenSSHPrivateKey.loadCertificate(keyPath: keyPath, certPath: certPath)
    }
}

/// Löser upp anslutningsplanen (mål-auth + ev. jump-host) för en värd —
/// samma logik/kontrakt som `App/AuthResolver.swift`s `resolveConnectionPlan`.
/// `store` är `nil` på anropsplatser som inte har en delad `HostStore`
/// tillgänglig; en host UTAN `jumpHostID` ansluter då fortfarande direkt,
/// men en host MED `jumpHostID` nekas anslutning istället för att tyst
/// hoppa förbi jump-hosten (fail-closed, inte en tyst degradering).
func resolveConnectionPlan(
    for host: Host, password: String?, store: HostStore?
) -> (auth: SSHAuth, jump: (target: SSHTarget, auth: SSHAuth)?)? {
    guard let auth = resolveAuth(for: host, password: password) else { return nil }
    guard let jumpID = host.jumpHostID else { return (auth, nil) }
    guard let jumpHost = store?.get(jumpID),
          jumpHost.jumpHostID == nil,
          let jumpAuth = resolveAuth(for: jumpHost, password: nil)
    else { return nil }
    return (auth, (target: jumpHost.target, auth: jumpAuth))
}
