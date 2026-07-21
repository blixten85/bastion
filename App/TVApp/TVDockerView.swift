#if os(tvOS)
import SwiftUI
import SSHCore

/// Docker-vy för tvOS — samma `DockerService`-anrop som `App/DockerView.swift`,
/// men ingen "Shell"-åtgärd (Siri Remote kan inte driva en interaktiv
/// terminal, se project.yml-kommentaren för `Bastion-tvOS`) och ingen
/// jump-host-uppslagning (se `TVAuthResolver.swift`).
@MainActor
final class TVDockerModel: ObservableObject {
    @Published var containers: [DockerContainer] = []
    @Published var errorMessage: String?
    @Published var loading = false
    @Published var busyRefs: Set<String> = []

    private let host: Host
    private let password: String?
    private let connector = ChainConnector<SSHSession>()

    init(host: Host, password: String?) {
        self.host = host
        self.password = password
    }

    private func ensureSession() async -> SSHSession? {
        await connector.ensure(
            connect: { [host, password] in
                // En jump-host ska ALDRIG hoppas över tyst (samma princip
                // som `App/AuthResolver.swift`s `resolveConnectionPlan`
                // dokumenterar) — utan jump-uppslagning här (se filkommentaren
                // ovan) skulle en värd synkad från iPhone/Mac med en
                // konfigurerad jump-host annars tyst anslutas DIREKT till
                // target, vilket kan exponera en server användaren
                // medvetet bara ville nå via en bastion (cubic P1).
                guard host.jumpHostID == nil else {
                    throw PlainMessageError(message: "Den här värden har en jump-host konfigurerad — det stöds inte i tvOS-Docker-vyn än.")
                }
                guard let auth = resolveAuth(for: host, password: password) else {
                    throw PlainMessageError(message: "Kan inte autentisera värden.")
                }
                return try await SSHConnectionChain.connect(target: host.target, targetAuth: auth, jump: nil)
            },
            open: { $0.target },
            onFailure: { [weak self] in self?.errorMessage = $0 }
        )
    }

    private func handleSessionFailure(_ error: Error, session: SSHSession) {
        guard case SSHError.remoteExit = error else {
            guard connector.target === session else { return }
            errorMessage = "\(error)"
            connector.invalidateIfCurrent(session)
            return
        }
        errorMessage = "\(error)"
    }

    // Bumpas vid varje `refresh()`-anrop — en överlappande, ÄLDRE refresh
    // (t.ex. den automatiska `.task`-körningen och ett manuellt
    // uppdaterings-tryck som råkar överlappa) ska inte få skriva över
    // resultatet från en NYARE, redan slutförd refresh (cubic P2).
    private var refreshGeneration = 0

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        loading = true
        defer { if generation == refreshGeneration { loading = false } }
        guard let s = await ensureSession() else { return }
        do {
            let list = try await DockerService.list(over: s)
            guard generation == refreshGeneration else { return }
            containers = list
            errorMessage = nil
        } catch {
            guard generation == refreshGeneration else { return }
            handleSessionFailure(error, session: s)
        }
    }

    func act(_ kind: DockerAction, on ref: String) async {
        // Reservera INNAN `ensureSession()`-väntan, inte efter — annars kan
        // två snabba tryck på samma container båda hinna förbi kollen
        // (i App/DockerView.swift markeras raden bara upptagen EFTER en
        // redan uppkopplad session, samma race finns där också — fixat
        // här, cubic P2).
        guard !busyRefs.contains(ref) else { return }
        busyRefs.insert(ref)
        defer { busyRefs.remove(ref) }
        guard let s = await ensureSession() else { return }
        do {
            switch kind {
            case .start: try await DockerService.start(ref, over: s)
            case .stop: try await DockerService.stop(ref, over: s)
            case .restart: try await DockerService.restart(ref, over: s)
            }
            await refresh()
        } catch {
            handleSessionFailure(error, session: s)
        }
    }

    func disconnect() {
        connector.disconnect()
    }
}

enum DockerAction { case start, stop, restart }

struct TVDockerView: View {
    @StateObject private var model: TVDockerModel

    init(host: Host, password: String?) {
        _model = StateObject(wrappedValue: TVDockerModel(host: host, password: password))
    }

    var body: some View {
        List {
            if let e = model.errorMessage {
                Section { Text(e).font(.footnote).foregroundStyle(.red) }
            }
            ForEach(model.containers, id: \.id) { c in
                row(c)
            }
        }
        .overlay {
            if model.loading && model.containers.isEmpty { ProgressView() }
            else if !model.loading && model.containers.isEmpty && model.errorMessage == nil {
                ContentUnavailableView("Inga containrar", systemImage: "shippingbox")
            }
        }
        .navigationTitle("Docker")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { await model.refresh() }
        .onDisappear { model.disconnect() }
    }

    private func row(_ c: DockerContainer) -> some View {
        HStack(spacing: 12) {
            Circle().fill(c.isRunning ? .green : .gray).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.body.weight(.medium))
                Text(c.image).font(.caption2).foregroundStyle(.secondary)
                Text(c.status).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busyRefs.contains(c.name) {
                ProgressView()
            } else {
                Menu {
                    if c.isRunning {
                        Button { act(.stop, c) } label: { Label("Stoppa", systemImage: "stop.fill") }
                        Button { act(.restart, c) } label: { Label("Starta om", systemImage: "arrow.clockwise") }
                    } else {
                        Button { act(.start, c) } label: { Label("Starta", systemImage: "play.fill") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func act(_ kind: DockerAction, _ c: DockerContainer) {
        Task { await model.act(kind, on: c.name) }
    }
}
#endif
