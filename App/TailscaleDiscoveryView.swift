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

    func fetch(source: Source, password: String?, store: HostStore?) async {
        state = .loading
        do {
            let suggestions: [(hostName: String, address: String)]
            switch source {
            case .local:
                #if !os(iOS)
                // `fetchLocal()` är synkron och väntar in att `tailscale`-
                // processen avslutas (`waitUntilExit()`) — körd direkt här
                // hade fryst hela sheeten under tiden, eftersom `fetch(...)`
                // körs på `@MainActor` (CodeRabbit-fynd, #115). `Task.detached`
                // flyttar den blockerande väntan av huvudtråden.
                suggestions = try await Task.detached(priority: .userInitiated) {
                    try TailscaleStatus.fetchLocal().suggestedHosts
                }.value
                #else
                // `fetchLocal()` finns inte på iOS (Foundation.Process
                // otillgängligt i sandlådan) — UI:t nedan visar aldrig
                // "Denna enhet"-alternativet på iOS, så den här grenen ska
                // aldrig nås i praktiken. `LoadState.failed` istället för
                // `fatalError` om den ändå skulle nås (t.ex. framtida
                // UI-ändring som missar plattformskontrollen).
                state = .failed("Inte tillgängligt på iOS.")
                return
                #endif
            case .remote(let host):
                guard let plan = resolveConnectionPlan(for: host, password: password, store: store) else {
                    state = .failed("Kan inte autentisera värden (eller dess jump-host, om en är vald).")
                    return
                }
                let chain = try await SSHConnectionChain.connect(
                    target: host.target, targetAuth: plan.auth, jump: plan.jump)
                defer { Task { await chain.close() } }
                let status = try await TailscaleStatus.fetch(over: chain.target)
                suggestions = status.suggestedHosts
            }
            state = .loaded(suggestions)
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
    /// För att slå upp en ev. jump-host, se `resolveConnectionPlan`. `nil`
    /// på anropsplatser utan delad store — bara en host UTAN jump-host
    /// ansluter då direkt; en host MED jumpHostID nekas anslutning
    /// (jump-hosten går inte att lösa upp utan store), se `resolveConnectionPlan`.
    var store: HostStore? = nil
    let onAddHost: (_ alias: String, _ hostName: String) -> Void

    @StateObject private var model = TailscaleDiscoveryModel()
    // "Denna enhet" finns bara på macOS (fetchLocal() kräver Foundation.
    // Process, otillgängligt i iOS-sandlådan) — iOS börjar därför direkt på
    // fjärrvärd, ingen källväljare att visa alls.
    #if os(iOS)
    @State private var useLocal = false
    #else
    @State private var useLocal = true
    #endif
    @State private var selectedHostID: Host.ID?
    @State private var password = ""

    private var selectedHost: Host? {
        hosts.first { $0.id == selectedHostID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    #if os(iOS)
                    Text("Föreslå SSH-värdar ur ett tailnet via en redan sparad fjärrvärd.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #else
                    Text("Föreslå SSH-värdar ur ett tailnet — antingen den här enhetens, eller en redan sparad fjärrvärds.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Källa", selection: $useLocal) {
                        Text("Denna enhet").tag(true)
                        Text("Fjärrvärd").tag(false)
                    }
                    .pickerStyle(.segmented)
                    #endif

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
                                await model.fetch(source: .local, password: nil, store: store)
                            } else if let selectedHost {
                                await model.fetch(source: .remote(selectedHost), password: password.isEmpty ? nil : password, store: store)
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
