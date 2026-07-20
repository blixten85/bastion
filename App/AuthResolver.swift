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
    case .bitwardenItem(let itemID):
        #if !os(iOS)
        return (try? BitwardenClient.fetchPassword(itemID: itemID)).map { SSHAuth.password($0) }
        #else
        // iOS saknar `Foundation.Process` — kräver native AutoFill/
        // `ASCredentialProviderExtension` istället, inte byggt här.
        return nil
        #endif
    }
}
#endif
