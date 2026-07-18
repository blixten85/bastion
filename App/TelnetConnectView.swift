#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// `.cover(item:)`/`.sheet(item:)` kräver `Identifiable` — SSHCore:s
/// `TelnetTarget` har ingen naturlig identitet (ren värdedata), så den
/// bygger en HÄR i UI-lagret istället för att lägga en SwiftUI-motiverad
/// konformance på den delade, plattformsoberoende typen.
extension TelnetTarget: Identifiable {
    public var id: String { "\(host):\(port)" }
}

/// Ansluter till en Telnet-värd — inget lösenord/nyckelval, till skillnad
/// från SSH: Telnet-autentisering (om servern ens kräver någon) sker inuti
/// själva terminalsessionen (login-prompt), inte som ett separat handskaknings-
/// steg. Ingen sparning i värdlistan (Termius saknar inte Telnet, men Bastion
/// gjorde det helt — se Sources/SSHCore/Telnet.swift).
struct TelnetConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hostName = ""
    @State private var portText = "23"
    let onConnect: (TelnetTarget) -> Void

    private var isValid: Bool {
        !hostName.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(portText).map { (1...65_535).contains($0) } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Värd") {
                    TextField("Värd (t.ex. 10.0.0.5)", text: $hostName)
                        .noAutocap().autocorrectionDisabled()
                    TextField("Port", text: $portText).numberPad()
                }
                Section {
                    Text("Telnet är okrypterat — använd bara på ett nätverk du litar på "
                         + "(t.ex. mot nätverksutrustning som saknar SSH-stöd).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Telnet")
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
        let cleanHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        onConnect(TelnetTarget(host: cleanHost, port: port))
        dismiss()
    }
}

#if canImport(SwiftTerm) && (os(iOS) || os(macOS))
/// Fullskärmscover-vy för en aktiv Telnet-session, motsvarar `SessionView` för SSH.
struct TelnetSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let target: TelnetTarget

    var body: some View {
        NavigationStack {
            BastionTelnetTerminal(target: target)
                .ignoresSafeArea(.container, edges: .bottom)
                .background(Color.black)
                .navigationTitle("\(target.host):\(target.port)")
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
#endif
