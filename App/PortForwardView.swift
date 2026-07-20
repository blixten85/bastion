#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Vilken typ av portvidarebefordran som skapas — matchar `ssh -L`/`-R`/`-D`.
/// Samma tre fall som LinuxApp:s motsvarighet (`PortForwardView.swift`).
enum PortForwardKind: String, CaseIterable, Identifiable {
    case local, remote, dynamic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Lokal (-L)"
        case .remote: return "Fjärr (-R)"
        case .dynamic: return "Dynamisk/SOCKS5 (-D)"
        }
    }
}

/// Ett aktivt portvidarebefordran, oavsett typ — `LocalPortForward`/
/// `RemotePortForward`/`DynamicPortForward` är tre skilda typer i SSHCore
/// (delar ingen gemensam protokoll), så den här slår ihop dem till en
/// enhetlig form UI:t kan lista och stänga utan att bry sig om vilken det är.
struct ActivePortForward: Identifiable {
    let id = UUID()
    let kind: PortForwardKind
    let bindHost: String
    let actualBindPort: Int
    /// Tomt för `.dynamic` (målet väljs av SOCKS-klienten per anslutning,
    /// finns inget fast mål att visa).
    let targetDescription: String
    let close: () async -> Void
}

@MainActor
final class PortForwardModel: ObservableObject {
    @Published var active: [ActivePortForward] = []
    @Published var errorMessage: String?
    @Published var starting = false
    private let request: ConnectRequest
    /// För att slå upp en ev. jump-host, se `resolveConnectionPlan`. `nil`
    /// på anropsplatser utan delad store — bara en host UTAN jump-host
    /// ansluter då direkt; en host MED jumpHostID nekas anslutning
    /// (jump-hosten går inte att lösa upp utan store), se `resolveConnectionPlan`.
    private let store: HostStore?
    private let connector = ChainConnector<SSHSession>()

    init(request: ConnectRequest, store: HostStore? = nil) {
        self.request = request
        self.store = store
    }

    private func ensureSession() async -> SSHSession? {
        await connector.ensure(
            connect: { [request, store] in
                guard let plan = resolveConnectionPlan(for: request.host, password: request.password, store: store) else {
                    throw PlainMessageError(message: "Kan inte autentisera värden (eller dess jump-host, om en är vald).")
                }
                return try await SSHConnectionChain.connect(
                    target: request.host.target, targetAuth: plan.auth, jump: plan.jump)
            },
            open: { $0.target },
            onFailure: { [weak self] in self?.errorMessage = $0 },
            onInterrupted: { [weak self] in
                // Bara om inget mer specifikt fel redan visas — annars kunde
                // den här generiska fallbacken skriva över ett meddelande som en
                // NYARE, samtidig anslutning redan hunnit sätta (cubic P2 på
                // PR #186).
                guard let self, self.errorMessage == nil else { return }
                self.errorMessage = "Anslutningen avbröts, försök igen."
            }
        )
    }

    /// `targetHost`/`targetPort` ignoreras för `.dynamic` (SOCKS-klienten
    /// väljer målet per anslutning — det är hela poängen med "dynamisk").
    func start(kind: PortForwardKind, bindPort: Int, targetHost: String, targetPort: Int) async {
        starting = true
        defer { starting = false }
        guard let s = await ensureSession() else { return }
        do {
            switch kind {
            case .local:
                let f = try await s.openLocalPortForward(bindPort: bindPort, targetHost: targetHost, targetPort: targetPort)
                active.append(ActivePortForward(
                    kind: .local, bindHost: f.bindHost, actualBindPort: f.actualBindPort,
                    targetDescription: "\(targetHost):\(targetPort)", close: { await f.close() }))
            case .remote:
                let f = try await s.openRemotePortForward(bindPort: bindPort, targetHost: targetHost, targetPort: targetPort)
                active.append(ActivePortForward(
                    kind: .remote, bindHost: request.host.hostName, actualBindPort: f.actualBindPort,
                    targetDescription: "\(targetHost):\(targetPort) (lokalt)", close: { await f.close() }))
            case .dynamic:
                let f = try await s.openDynamicPortForward(bindPort: bindPort)
                active.append(ActivePortForward(
                    kind: .dynamic, bindHost: f.bindHost, actualBindPort: f.actualBindPort,
                    targetDescription: "", close: { await f.close() }))
            }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    func stop(_ forward: ActivePortForward) async {
        await forward.close()
        active.removeAll { $0.id == forward.id }
    }

    func disconnect() {
        let forwards = active
        active = []
        // Tunnlarna stängs FÖRE kedjan — de dirigerar trafik genom
        // kedjans session, så den ska hållas vid liv tills varje tunnels
        // egen stängning hunnit köra klart.
        connector.disconnect(before: {
            for f in forwards { await f.close() }
        })
    }
}

/// Portvidarebefordran-vyn för App/ (iOS/macOS) — samma modell/beteende som
/// LinuxApp:s `PortForwardView.swift`, bara SwiftUI istället för SwiftCrossUI.
struct PortForwardView: View {
    @StateObject private var model: PortForwardModel
    @State private var kind: PortForwardKind = .local
    @State private var bindPortText = "0"
    @State private var targetHostText = ""
    @State private var targetPortText = ""

    init(request: ConnectRequest, store: HostStore? = nil) {
        self._model = StateObject(wrappedValue: PortForwardModel(request: request, store: store))
    }

    var body: some View {
        Form {
            if let e = model.errorMessage {
                Section { Text(e).foregroundStyle(.red) }
            }

            Section("Ny tunnel") {
                Picker("Typ", selection: $kind) {
                    ForEach(PortForwardKind.allCases) { k in Text(k.title).tag(k) }
                }
                TextField("Lokal bindport (0 = valfri ledig)", text: $bindPortText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if kind != .dynamic {
                    TextField("Målvärd (t.ex. 10.0.0.5)", text: $targetHostText)
                        .noAutocap().autocorrectionDisabled()
                    TextField("Målport", text: $targetPortText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Button {
                    Task { await start() }
                } label: {
                    if model.starting {
                        ProgressView()
                    } else {
                        Text("Starta")
                    }
                }
                .disabled(model.starting || !isValid)
            }

            Section("Aktiva tunnlar") {
                if model.active.isEmpty {
                    Text("Inga aktiva tunnlar.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.active) { f in row(f) }
                }
            }
        }
        .navigationTitle("Portvidarebefordran")
        .navInlineTitle()
        .onDisappear { model.disconnect() }
    }

    private var isValid: Bool {
        guard Int(bindPortText) != nil else { return false }
        if kind == .dynamic { return true }
        guard let p = Int(targetPortText), p > 0, p <= 65_535 else { return false }
        return !targetHostText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func start() async {
        guard let bindPort = Int(bindPortText) else { return }
        let targetPort = Int(targetPortText) ?? 0
        await model.start(kind: kind, bindPort: bindPort, targetHost: targetHostText, targetPort: targetPort)
    }

    private func row(_ f: ActivePortForward) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.kind.title).font(.body.weight(.medium))
                if f.targetDescription.isEmpty {
                    Text("\(f.bindHost):\(f.actualBindPort)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(f.bindHost):\(f.actualBindPort) → \(f.targetDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                Task { await model.stop(f) }
            } label: {
                Image(systemName: "xmark.circle")
            }
        }
    }
}
#endif
