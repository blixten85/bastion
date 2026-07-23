#if os(tvOS)
import Foundation
import SSHCore

/// Trimmad motsvarighet till `App/AuthResolver.swift` — `TVApp/` delar
/// inget med `App/`-roten (egen target, se project.yml-kommentaren för
/// `Bastion-tvOS`), så samma duplicerings-mönster som redan används för
/// LinuxApp (ett helt separat SwiftPM-paket av samma skäl).
///
/// Ingen jump-host-uppslagning i den här första versionen — TVDashboardView
/// har ingen delad `HostStore`-instans att slå upp en jump-host i (bara
/// `store.all()` en gång vid `onAppear`), och Docker-vyn är det första
/// tv-flödet som ens behöver en riktig SSH-session. Kan läggas till senare
/// om det efterfrågas (se [[project-bastion-tvos-watchos-mandate]]).
func resolveAuth(for host: Host, password: String?) -> SSHAuth? {
    switch host.auth {
    case .askPassword:
        return password.map { SSHAuth.password($0) }
    case .keyFile(let path):
        // Värdar med .keyFile som auth-metod kan inte autentiseras på tvOS om
        // de synkats från iPhone/Mac — tvOS har inget user-accessible fil-system
        // och sökvägar synkas aldrig mellan plattformar. Användaren måste
        // återanvända auth-metoden (t.ex. byta till .keychainKey eller lösenord)
        // för att kunna använda värdarna på tvOS.
        return try? OpenSSHPrivateKey.load(path: path)
    case .agentDefault:
        let def = ("~/.ssh/id_ed25519" as NSString).expandingTildeInPath
        return try? OpenSSHPrivateKey.load(path: def)
    case .keychainKey(let id):
        // Värdar med .keychainKey som auth-metod kan inte autentiseras på tvOS om
        // de synkats från iPhone/Mac om keychain-access-groups inte är konfigurerad
        // i entitlements för iOS/tvOS-delning. Utan korrekt `keychain-access-groups`
        // returnerar Keychain.get(id) nil på tvOS för poster som sparats på iOS.
        guard let pem = Keychain.get(id) else { return nil }
        return try? OpenSSHPrivateKey.parse(pem)
    case .certificateFile(let keyPath, let certPath):
        return try? OpenSSHPrivateKey.loadCertificate(keyPath: keyPath, certPath: certPath)
    case .bitwardenItem:
        // Samma strukturella blockerare som iOS (inget `Foundation.Process`)
        // — se `App/AuthResolver.swift` för den fullständiga motiveringen.
        return nil
    }
}
#endif
