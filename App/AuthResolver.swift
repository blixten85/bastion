#if canImport(SwiftUI)
import Foundation
import SSHCore

/// Bygger `SSHAuth` för en värd. Delas av dashboard och terminal så bägge
/// autentiserar likadant.
func resolveAuth(for host: Host, password: String?) -> SSHAuth? {
    switch host.auth {
    case .askPassword:
        return password.map { SSHAuth.password($0) }
    case .keyFile(let path):
        return try? OpenSSHPrivateKey.load(path: path)
    case .agentDefault:
        let def = ("~/.ssh/id_ed25519" as NSString).expandingTildeInPath
        return try? OpenSSHPrivateKey.load(path: def)
    case .keychainKey(let id):
        guard let pem = Keychain.get(id) else { return nil }
        return try? OpenSSHPrivateKey.parse(pem)
    case .certificateFile(let keyPath, let certPath):
        return try? OpenSSHPrivateKey.loadCertificate(keyPath: keyPath, certPath: certPath)
    }
}

/// Löser upp target-auth OCH, om `host.jumpHostID` är satt, jump-endpointen
/// — enda stället som känner till den regeln, delad av alla anropsplatser
/// som kan koppla upp en `SSHConnectionChain`. Returnerar `nil` om target
/// INTE kan autentiseras, eller om en konfigurerad jump-host är satt men
/// saknas i `store`/inte kan autentiseras: en jump-host ska ALDRIG hoppas
/// över tyst, det vore en säkerhetsregression för den som medvetet satt
/// upp en (se `SessionView.plan`, samma kontrakt).
func resolveConnectionPlan(
    for host: Host, password: String?, store: HostStore?
) -> (auth: SSHAuth, jump: (target: SSHTarget, auth: SSHAuth)?)? {
    guard let auth = resolveAuth(for: host, password: password) else { return nil }
    guard let jumpID = host.jumpHostID else { return (auth, nil) }
    guard let jumpHost = store?.get(jumpID),
          let jumpAuth = resolveAuth(for: jumpHost, password: nil)
    else { return nil }
    return (auth, (target: jumpHost.target, auth: jumpAuth))
}
#endif
