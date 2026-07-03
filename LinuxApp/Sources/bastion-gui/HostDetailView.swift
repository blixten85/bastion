import SSHCore
import SwiftCrossUI

/// Visas när en värd väljs i sidopanelen: lösenordsgrind om det behövs,
/// annars dashboard + kommandokörning. Motsvarar `App/HostDetailView.swift`.
struct HostDetailView: View {
    let host: Host
    @State private var password = ""
    @State private var connected = false
    @State private var resolvedPassword: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(host.alias.isEmpty ? host.hostName : host.alias).font(.title2)
            Text("\(host.user)@\(host.hostName):\(host.port)").foregroundColor(.gray)

            if needsPassword && !connected {
                passwordGate
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    DashboardView(host: host, password: resolvedPassword)
                    Divider()
                    TerminalSessionView(host: host, password: resolvedPassword)
                }
            }
        }
        .padding()
    }

    private var needsPassword: Bool {
        if case .askPassword = host.auth { return true }
        return false
    }

    private var passwordGate: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Den här värden kräver lösenord.").foregroundColor(.gray)
            HStack {
                SecureField("Lösenord", text: $password)
                Button("Anslut") {
                    resolvedPassword = password
                    connected = true
                }
                .disabled(password.isEmpty)
            }
        }
        .padding(.top)
    }
}
