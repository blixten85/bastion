#if os(tvOS)
import SwiftUI
import SSHCore

/// Läser samma `~/.bastion/hosts.json` som iOS/macOS-appen (delad via
/// iCloud/synk-lagret, se `SyncEngine`) — tv-appen skriver aldrig till
/// den, bara läser + skickar Wake-on-LAN.
struct TVDashboardView: View {
    @State private var hosts: [Host] = []
    @State private var wakingID: UUID?
    @State private var errorMessage: String?

    private let store = HostStore()

    var body: some View {
        NavigationStack {
            List(hosts) { host in
                HStack {
                    VStack(alignment: .leading) {
                        Text(host.alias).font(.headline)
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
            .navigationTitle("Bastion")
            .onAppear { hosts = store.all() }
            .alert("Kunde inte väcka värden", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
        }
    }

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
