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
/// Kastar (istället för att returnera `nil`) för auth-metoder som
/// STRUKTURELLT inte kan fungera på tvOS än, med ett specifikt skäl per
/// fall — annars såg alla dessa likadana ut i UI:t ("Kan inte autentisera
/// värden"), som om värden var felkonfigurerad snarare än att förklara VAD
/// som saknas (cubic-fynd, PR #196). `.keyFile`/`.agentDefault` pekar på
/// filsökvägar som synkas från iPhone/Mac — tvOS har ingen delad
/// fil-lagring att synka DEM till. `.keychainKey` pekar på en post i
/// iOS/Mac-nyckelringen — tvOS-appen har ett eget bundle-ID och en egen
/// Keychain-access-group, ingen delad Keychain-grupp är konfigurerad än
/// (skulle kräva omprovisionering, görs inte som en blind sen-kvälls-ändring).
func resolveAuth(for host: Host, password: String?) throws -> SSHAuth {
    switch host.auth {
    case .askPassword:
        guard let password else {
            throw PlainMessageError(message: "Den här värden kräver lösenord, men inget skickades med.")
        }
        return .password(password)
    case .keyFile:
        throw PlainMessageError(message: "Den här värden använder en nyckelfil synkad från iPhone/Mac — tvOS har ingen delad fil-lagring att nå den från. Byt till lösenordsautentisering för att använda värden här.")
    case .agentDefault:
        throw PlainMessageError(message: "SSH-agent-autentisering finns inte på tvOS. Byt till lösenordsautentisering för att använda värden här.")
    case .keychainKey:
        throw PlainMessageError(message: "Den här värdens nyckel ligger i iPhone/Mac-nyckelringen — tvOS-appen delar inte nyckelring med de andra plattformarna än. Byt till lösenordsautentisering för att använda värden här.")
    case .certificateFile(let keyPath, let certPath):
        guard let auth = try? OpenSSHPrivateKey.loadCertificate(keyPath: keyPath, certPath: certPath) else {
            throw PlainMessageError(message: "Kunde inte läsa certifikatfilen för den här värden.")
        }
        return auth
    case .bitwardenItem:
        // Samma strukturella blockerare som iOS (inget `Foundation.Process`)
        // — se `App/AuthResolver.swift` för den fullständiga motiveringen.
        throw PlainMessageError(message: "Bitwarden-integrationen stöds inte på tvOS. Byt till lösenordsautentisering för att använda värden här.")
    }
}
#endif
