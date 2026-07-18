#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Anslut till en ad-hoc värd UTAN att spara den i host-listan — Termius
/// kallar detta "Quick Connect". Bygger en `Host` i minnet (aldrig skickad
/// till `HostStore`) och öppnar samma `ConnectRequest`-flöde som en sparad
/// värd, så terminalen/jump-host-uppslagningen etc. fungerar identiskt.
struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hostName = ""
    @State private var user = ""
    @State private var portText = "22"
    @State private var password = ""
    let onConnect: (ConnectRequest) -> Void

    private var isValid: Bool {
        !hostName.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(portText).map { (1...65_535).contains($0) } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Värd") {
                    TextField("Värd (t.ex. 10.0.0.5)", text: $hostName)
                        .noAutocap().autocorrectionDisabled()
                    TextField("Användare", text: $user)
                        .noAutocap().autocorrectionDisabled()
                    TextField("Port", text: $portText).numberPad()
                }
                Section("Autentisering") {
                    SecureField("Lösenord (tomt = agent/standardnyckel)", text: $password)
                }
                Section {
                    Text("Den här värden sparas INTE i din värdlista — perfekt för en "
                         + "engångsanslutning. Lägg till den vanligt med + om du vill återansluta senare.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Snabbanslutning")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Avbryt") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Anslut") { connect() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func connect() {
        guard let port = Int(portText) else { return }
        // Lösenordet skickas OBESKURET — trimning hade tyst korrumperat ett
        // giltigt lösenord med inlednings-/avslutande blanktecken (cubic-
        // fynd, PR #173). `isEmpty` (inte trimmat) avgör bara vilket
        // auth-läge som väljs.
        let host = Host(
            alias: "", hostName: hostName, user: user, port: port,
            auth: password.isEmpty ? .agentDefault : .askPassword)
        onConnect(ConnectRequest(host: host, password: password.isEmpty ? nil : password))
        dismiss()
    }
}
#endif
