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
                            VStack(alignment: .leading) {
                                Text(host.alias.isEmpty ? host.hostName : host.alias).font(.headline)
                                Text("\(host.user)@\(host.hostName):\(host.port)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
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
#endif
