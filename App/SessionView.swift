#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Håller en aktiv terminalsession för en vald värd.
struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    let request: ConnectRequest

    var body: some View {
        NavigationStack {
            Group {
                if let auth = resolveAuth(for: request.host, password: request.password) {
                    BastionTerminal(target: request.host.target, auth: auth,
                                    initialCommand: request.initialCommand)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .background(Color.black)
                } else {
                    ContentUnavailableView(
                        "Kan inte autentisera", systemImage: "lock.slash",
                        description: Text("Kontrollera nyckelfil eller lösenord för värden."))
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
