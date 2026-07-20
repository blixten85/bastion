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
    case .bitwardenItem:
        // BÅDA App/-plattformarna saknar en säker väg att köra `bw` här:
        // iOS har inget `Foundation.Process` alls, och macOS-målets App
        // Sandbox (`com.apple.security.app-sandbox: true`, se
        // `App/project.yml`) dödar processen med ett okatchbart SIGTRAP så
        // fort `Process.run()` försöker starta en extern, osignerad binär
        // som `bw` — empiriskt verifierat på riktig macOS-hårdvara
        // (2026-07-20). `#if !os(iOS)` här hade fortsatt låtit detta nås på
        // macOS för en värd synkad från LinuxApp, där `bw` faktiskt fungerar
        // (sentry CRITICAL +
        // cubic P1 på PR #185: UI-filtret i HostEditView hindrar bara NYA
        // val, inte redan synkade värdar som väljs för ANSLUTNING). Kraschen
        // är inte en Swift-error ett `do/catch` kan fånga, så det enda
        // korrekta är att aldrig försöka — strukturellt omöjligt, inte bara
        // UI-dolt.
        return nil
    }
}
#endif
