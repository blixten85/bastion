#if os(tvOS)
import SwiftUI
import SSHCore

/// Läser tv-enhetens EGEN lokala `~/.bastion/hosts.json` — tv-appen skriver
/// aldrig till den, bara läser + skickar Wake-on-LAN. Ingen automatisk synk:
/// `HostStore.sync(with:)` kräver en explicit vald leverantör (Dropbox/
/// Google Drive/OneDrive/krypterad mapp) + OAuth-inloggning/lösenfras, en
/// UI-flöde som inte byggts här (opraktiskt med Siri Remote-textinmatning,
/// se PR-beskrivning för scope-beslutet). Tills det finns är listan tom
/// tills en användare synkar från tv-appen själv — visas ärligt som ett
/// tomt-state nedan, inte dolt/tyst.
struct TVDashboardView: View {
    @State private var hosts: [Host] = []
    @State private var wakingID: UUID?
    @State private var errorMessage: String?
    // Docker-vyn kräver en riktig SSH-session — `.askPassword`-värdar
    // behöver lösenordet frågat FÖRST (samma mönster som HostListViews
    // motsvarande alert i App/), övriga auth-typer löser sig själva i
    // `TVAuthResolver.resolveAuth`.
    @State private var passwordFor: Host?
    @State private var passwordInput = ""
    @State private var dockerTarget: DockerTarget?

    private let store = HostStore()

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    ContentUnavailableView(
                        "Inga värdar",
                        systemImage: "server.rack",
                        description: Text("Synk mot tv-appen är inte byggt än — lägg till/synka värdar i iPhone- eller Mac-appen. Se ROADMAP.md.")
                    )
                } else {
                    List(hosts) { host in
                        HStack {
                            Button {
                                openDocker(host)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(host.alias.isEmpty ? host.hostName : host.alias).font(.headline)
                                    Text("\(host.user)@\(host.hostName):\(host.port)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            if let mac = host.macAddress, !mac.isEmpty {
                                Button {
                                    wake(host: host, mac: mac)
                                } label: {
                                    if wakingID == host.id {
                                        ProgressView()
                                    } else {
                                        Label("Väck", systemImage: "power")
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(wakingID != nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bastion")
            .onAppear { hosts = store.all() }
            .alert("Kunde inte väcka värden", isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } }
            ), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
            .alert("Lösenord", isPresented: .constant(passwordFor != nil)) {
                SecureField("Lösenord", text: $passwordInput)
                Button("Anslut") {
                    if let h = passwordFor {
                        dockerTarget = DockerTarget(host: h, password: passwordInput)
                    }
                    passwordFor = nil; passwordInput = ""
                }
                Button("Avbryt", role: .cancel) { passwordFor = nil; passwordInput = "" }
            }
            .navigationDestination(item: $dockerTarget) { target in
                TVDockerView(host: target.host, password: target.password)
            }
        }
    }

    private func openDocker(_ host: Host) {
        if case .askPassword = host.auth {
            passwordFor = host
        } else {
            dockerTarget = DockerTarget(host: host, password: nil)
        }
    }

    @MainActor
    private func wake(host: Host, mac: String) {
        wakingID = host.id
        Task {
            do {
                try await WakeOnLan.send(mac: mac)
            } catch {
                errorMessage = error.localizedDescription
            }
            wakingID = nil
        }
    }
}

/// `navigationDestination(item:)` kräver `Identifiable` — `id` behöver
/// inte vara stabil över flera öppningar av SAMMA värd, bara unik per
/// navigeringstillfälle (en ny struct skapas varje gång `openDocker`
/// körs).
private struct DockerTarget: Identifiable, Hashable {
    let id = UUID()
    let host: Host
    let password: String?

    // Manuell konformans — `Host` är `Equatable` men inte `Hashable`, så
    // auto-syntes fungerar inte. `id` är redan unik per navigeringstillfälle
    // (se kommentaren ovan), räcker som identitet här.
    static func == (lhs: DockerTarget, rhs: DockerTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
#endif
