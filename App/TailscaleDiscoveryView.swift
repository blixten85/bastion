#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Föreslå SSH-värdar ur ett tailnet — två källor att välja mellan
/// (användaren avgör vad som är bekvämast, inte appen): den här enheten
/// (`fetchLocal`) eller en redan sparad fjärrvärd (`fetch(over:)`, som
/// Dashboard-datan). Samma modell som LinuxApp:s motsvarighet.
@MainActor
final class TailscaleDiscoveryModel: ObservableObject {
    enum Source { case local, remote(Host) }
    enum LoadState {
        case idle
        case loading
        case loaded([(hostName: String, address: String)])
        case failed(String)
    }
    @Published var state: LoadState = .idle

    func fetch(source: Source, password: String?) async {
        state = .loading
        do {
            let status: TailscaleStatus
            switch source {
            case .local:
                status = try TailscaleStatus.fetchLocal()
            case .remote(let host):
                guard let auth = resolveAuth(for: host, password: password) else {
                    state = .failed("Kan inte autentisera värden.")
                    return
                }
                let session = SSHSession(target: host.target, auth: auth)
                try await session.connect()
                defer { Task { await session.close() } }
                status = try await TailscaleStatus.fetch(over: session)
            }
            state = .loaded(status.suggestedHosts)
        } catch {
            state = .failed("\(error)")
        }
    }
}

/// Motsvarar `ImportConfigView`/`WireGuardProfileListView` som toppnivåsheet.
/// `onAddHost` öppnar samma "Ny värd"-flöde som +-knappen, bara förifyllt
/// med tailnet-adressen — Tailscale känner inte till SSH-användarnamnet,
/// så det sista steget är alltid det vanliga redigeringsläget.
struct TailscaleDiscoveryView: View {
    @Environment(\.dismiss) private var dismiss
    let hosts: [Host]
    let onAddHost: (_ alias: String, _ hostName: String) -> Void

    @StateObject private var model = TailscaleDiscoveryModel()
    @State private var useLocal = true
    @State private var selectedHostID: Host.ID?
    @State private var password = ""

    private var selectedHost: Host? {
        hosts.first { $0.id == selectedHostID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Föreslå SSH-värdar ur ett tailnet — antingen den här enhetens, eller en redan sparad fjärrvärds.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Källa", selection: $useLocal) {
                        Text("Denna enhet").tag(true)
                        Text("Fjärrvärd").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if !useLocal {
                        Picker("Värd", selection: $selectedHostID) {
                            Text("Välj…").tag(Host.ID?.none)
                            ForEach(hosts) { h in
                                Text(h.alias.isEmpty ? h.hostName : h.alias).tag(Host.ID?.some(h.id))
                            }
                        }
                        SecureField("Lösenord (om värden kräver det)", text: $password)
                    }

                    Button("Hämta") {
                        Task {
                            if useLocal {
                                await model.fetch(source: .local, password: nil)
                            } else if let selectedHost {
                                await model.fetch(source: .remote(selectedHost), password: password.isEmpty ? nil : password)
                            }
                        }
                    }
                    .disabled(!useLocal && selectedHost == nil)
                }

                Section("Förslag") {
                    resultsView
                }
            }
            .navigationTitle("Tailscale-värdar")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Stäng") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView("Hämtar…")
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.secondary)
        case .loaded(let suggestions):
            if suggestions.isEmpty {
                Text("Inga online-peers med IP hittades i det tailnetet.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(suggestions, id: \.hostName) { suggestion in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.hostName)
                            Text(suggestion.address).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Lägg till") {
                            onAddHost(suggestion.hostName, suggestion.address)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
#endif
