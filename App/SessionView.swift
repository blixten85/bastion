#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Håller en aktiv terminalsession för en vald värd.
struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    let request: ConnectRequest
    /// För att slå upp en ev. jump-host (`request.host.jumpHostID`). `nil`
    /// på anropsplatser som saknar en delad store — anslutning sker då
    /// direkt, precis som innan jump-stöd fanns (ingen regression, bara
    /// ingen jump-kedja tillgänglig därifrån ännu).
    var store: HostStore? = nil

    /// Resultatet av att slå upp anslutningsplanen: `.some` med ev. jump
    /// bara om ALLT som krävs kunde lösas. Om `request.host.jumpHostID` är
    /// satt men jump-hosten saknas i storen eller inte kan autentiseras,
    /// ska HELA anslutningen misslyckas (samma "kan inte autentisera"-läge
    /// som target-autentisering redan har) — INTE tyst hoppa över den
    /// konfigurerade jump-hosten och ansluta direkt, vilket vore en tyst
    /// säkerhetsregression för den som medvetet satt upp en jump-host.
    private var plan: (auth: SSHAuth, jump: (target: SSHTarget, auth: SSHAuth)?)? {
        guard let auth = resolveAuth(for: request.host, password: request.password) else { return nil }
        guard let jumpID = request.host.jumpHostID else { return (auth, nil) }
        guard let jumpHost = store?.get(jumpID),
              let jumpAuth = resolveAuth(for: jumpHost, password: nil)
        else { return nil }
        return (auth, (target: jumpHost.target, auth: jumpAuth))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    BastionTerminal(target: request.host.target, auth: plan.auth,
                                    jump: plan.jump,
                                    initialCommand: request.initialCommand)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .background(Color.black)
                } else {
                    ContentUnavailableView(
                        "Kan inte autentisera", systemImage: "lock.slash",
                        description: Text("Kontrollera nyckelfil eller lösenord för värden (eller dess jump-host, om en är vald)."))
                }
            }
            .navigationTitle(request.host.alias.isEmpty ? request.host.hostName : request.host.alias)
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Klar") { dismiss() }
                }
            }
        }
    }
}
#endif
