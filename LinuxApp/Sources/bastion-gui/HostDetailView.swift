import SSHCore
import SwiftCrossUI

/// Visas när en värd väljs i sidopanelen: lösenordsgrind om det behövs,
/// annars dashboard + kommandokörning. Motsvarar `App/HostDetailView.swift`.
struct HostDetailView: View {
    let host: Host
    @State private var password = ""
    @State private var connected = false
    @State private var resolvedPassword: String?
    @State private var showDocker = false
    @State private var showSnippets = false
    @State private var showCommandLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(host.alias.isEmpty ? host.hostName : host.alias).font(.title2)
                    Text("\(host.user)@\(host.hostName):\(host.port)").foregroundColor(.gray)
                }
                Spacer()
                if connected || !needsPassword {
                    Button("Docker") { showDocker = true }
                    Button("Snippets") { showSnippets = true }
                    Button("Bibliotek") { showCommandLibrary = true }
                }
            }

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
        .sheet(isPresented: $showDocker) {
            DockerView(host: host, password: resolvedPassword)
        }
        .sheet(isPresented: $showSnippets) {
            SnippetListView(host: host, password: resolvedPassword)
        }
        .sheet(isPresented: $showCommandLibrary) {
            CommandLibraryView(host: host, password: resolvedPassword)
        }
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
