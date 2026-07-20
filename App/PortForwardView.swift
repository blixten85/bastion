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
    private var chain: SSHConnectionChain?
    // Cachar det pågående anslutningsförsöket så samtidiga anrop väntar in
    // samma försök i stället för att skapa varsin kedja var, och så
    // disconnect() kan avbryta det (samma mönster som DockerModel/
    // SFTPBrowserModel, PR #172).
    private var connectingTask: Task<SSHSession?, Never>?
    // Samma skydd som `DockerModel.isTornDown`: `start()` startas från vyn
    // som en fristående `Task { }`, inte `.task { }`, så den avbryts inte
    // automatiskt av `.onDisappear`. Utan flaggan skulle `ensureSession()`
    // kunna återuppliva en ny anslutning efter att `disconnect()` redan kört
    // (cubic P2 på PR #172).
    private var isTornDown = false

    init(request: ConnectRequest, store: HostStore? = nil) {
        self.request = request
        self.store = store
    }

    private func ensureSession() async -> SSHSession? {
        guard !isTornDown else { return nil }
        if let chain { return chain.target }
        if let connectingTask {
            let result = await connectingTask.value
            // `disconnect()` kan ha kört FÄRDIGT (nollat `chain`) medan vi
            // väntade på en ANNAN anropares `connectingTask` här — utan den
            // här omkontrollen skulle vi returnera en session som redan är
            // (eller snart blir) stängd, i stället för att upptäcka teardownen
            // (cubic P2 på PR #172, samma race som förklaras nedan för den
            // task vi själva startar).
            guard !isTornDown, let result, chain?.target === result else {
                // Sätts bara om (1) vyn INTE lämnats — annars är den som
                // skulle visa felet redan borta — OCH (2) tasken INTE redan
                // satt ett SPECIFIKT felmeddelande i sitt eget catch-block
                // (auth-fel, anslutningsfel) — annars skriver denna generiska
                // fallback tyst över den faktiska, mer användbara orsaken
                // (cubic P2 på PR #172). Utan fallback ALLS hade en snabb
                // avbryt-och-försök-igen fortfarande failat tyst (sentry-fynd).
                if !isTornDown && errorMessage == nil {
                    errorMessage = "Anslutningen avbröts, försök igen."
                }
                return nil
            }
            return result
        }

        let task = Task<SSHSession?, Never> { [weak self] in
            guard let self else { return nil }
            guard let plan = resolveConnectionPlan(for: self.request.host, password: self.request.password, store: self.store) else {
                self.errorMessage = "Kan inte autentisera värden (eller dess jump-host, om en är vald)."
                return nil
            }
            do {
                let c = try await SSHConnectionChain.connect(
                    target: self.request.host.target, targetAuth: plan.auth, jump: plan.jump)
                // disconnect() kan ha körts (vyn stängd) medan vi väntade på
                // connect() — utan den här kollen skulle vi återuppliva
                // self.chain EFTER att disconnect() redan städat, och den nya
                // anslutningen skulle aldrig stängas.
                guard !Task.isCancelled else {
                    await c.close()
                    return nil
                }
                self.chain = c
                return c.target
            } catch {
                self.errorMessage = "\(error)"
                return nil
            }
        }
        connectingTask = task
        let result = await task.value
        connectingTask = nil
        // Se kommentaren ovan vid den delade `connectingTask`-vägen: `disconnect()`
        // kan ha hunnit köra (och nolla `chain`) medan VI väntade på vår egen
        // task, trots att tasken själv redan kollade `Task.isCancelled` innan
        // den satte `self.chain` — ett fönster kvarstår mellan den kollen och
        // att `await task.value` returnerar här. Utan omkontrollen skulle en
        // uppringare som redan lämnat vyn ändå kunna få tillbaka en session
        // och öppna en tunnel genom en kedja som är på väg att stängas
        // (cubic P2 på PR #172, med föreslagen fix).
        guard !isTornDown, let result, chain?.target === result else {
            // Se kommentaren vid den delade vägen ovan: bara om vyn INTE
            // lämnats OCH tasken inte redan satt ett specifikt fel (cubic P2).
            if !isTornDown && errorMessage == nil {
                errorMessage = "Anslutningen avbröts, försök igen."
            }
            return nil
        }
        return result
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
        isTornDown = true
        connectingTask?.cancel()
        let c = chain
        chain = nil
        let forwards = active
        active = []
        Task {
            for f in forwards { await f.close() }
            await c?.close()
        }
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
