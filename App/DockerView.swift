#if canImport(SwiftUI)
import SwiftUI
import SSHCore

enum DockerAction { case start, stop, restart }

@MainActor
final class DockerModel: ObservableObject {
    @Published var containers: [DockerContainer] = []
    @Published var errorMessage: String?
    @Published var loading = false
    // Set, inte en enda String? — annars kan en åtgärd på en container som
    // avslutas rensa "upptagen"-indikatorn för en annan medan dess egen
    // åtgärd fortfarande pågår (om användaren hinner starta båda i tur och ordning).
    @Published var busyRefs: Set<String> = []
    private let request: ConnectRequest
    /// För att slå upp en ev. jump-host, se `resolveConnectionPlan`. `nil`
    /// på anropsplatser utan delad store — bara en host UTAN jump-host
    /// ansluter då direkt; en host MED jumpHostID nekas anslutning
    /// (jump-hosten går inte att lösa upp utan store), se `resolveConnectionPlan`.
    private let store: HostStore?
    private var chain: SSHConnectionChain?
    // Cachar det pågående anslutningsförsöket så samtidiga anrop (t.ex.
    // refresh() och act() strax efter varandra, innan connect() svarat) väntar
    // in samma försök i stället för att skapa varsin kedja var.
    private var connectingTask: Task<SSHSession?, Never>?
    // `act(_:on:)` startas från vyn som en FRISTÅENDE `Task { }` (inte
    // `.task { }`), så den avbryts INTE automatiskt av `.onDisappear`. Utan
    // den här flaggan skulle en `act()` som redan hunnit förbi `ensureSession()`
    // innan `disconnect()` kördes ändå kunna anropa `refresh()` EFTER
    // teardown, vars `ensureSession()` då återupplivar en helt ny anslutning
    // som aldrig städas (ingen framtida `onDisappear` kommer köras igen) —
    // cubic P2 på PR #172.
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
            // Samma omkontroll som efter EGEN task nedan — utan den kunde en
            // samtidig anropare som väntar in NÅGON ANNANS connectingTask få
            // tillbaka en session trots att disconnect() redan hunnit
            // stänga den under tiden (sentry HIGH + CodeRabbit + cubic P2
            // på PR #172, samma mönster som PortForwardModel redan hade).
            guard !isTornDown, let result, chain?.target === result else { return nil }
            return result
        }

        // Skapad inifrån en @MainActor-metod (inte .detached), så den ärver
        // MainActor-isoleringen — säkert att sätta errorMessage direkt här.
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
                // anslutningen skulle aldrig stängas (samma CodeRabbit-mönster
                // som SFTPBrowserModel, PR #172).
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
        // Samma race som förklarades ovan i tasken själv, men täcker fönstret
        // MELLAN att tasken kollade `Task.isCancelled` och att `await
        // task.value` returnerar här: `disconnect()` kan ha hunnit köra
        // FÄRDIGT i det fönstret och redan nollat `chain`/satt `isTornDown`,
        // utan att tasken själv märkte det. Utan omkontrollen skulle en
        // uppringare som redan lämnat vyn ändå kunna få tillbaka en session
        // och läcka den öppna kedjan (sentry HIGH på PR #172).
        guard !isTornDown, let result, chain?.target === result else { return nil }
        return result
    }

    /// Ett `docker`-kommando som bara gav en icke-noll exitkod
    /// (`SSHError.remoteExit`) säger inget om SJÄLVA anslutningen — den är
    /// fortsatt frisk och `chain` ska cachas kvar. ALLT ANNAT (handskaknings-/
    /// auth-fel som bara syns vid första kanalanvändningen genom en jump,
    /// kanalfel, ...) betyder att den cachade sessionen är trasig; utan att
    /// stänga och nolla `chain` här skulle `refresh()`/`act()` bara fortsätta
    /// återanvända samma döda session och den öppna jump-anslutningen läcka
    /// för alltid (cubic P2 på PR #172).
    ///
    /// `session` är den session ANROPET faktiskt kördes mot — om `act()`/
    /// `refresh()` överlappar (t.ex. en gammal `act()` misslyckas EFTER att
    /// en ny `ensureSession()` redan hunnit återansluta) ska ett sent fel
    /// från den GAMLA sessionen inte stänga den NYA, redan uppkopplade
    /// kedjan (cubic P2 på PR #172).
    private func handleSessionFailure(_ error: Error, session: SSHSession) {
        guard case SSHError.remoteExit = error else {
            // Identitetskontrollen görs FÖRE errorMessage sätts — annars
            // skriver ett sent fel från en GAMMAL, redan utbytt session
            // över felmeddelandet för en redan lyckad, ny anslutning
            // (cubic P2 på PR #172).
            guard chain?.target === session else { return }
            errorMessage = "\(error)"
            let c = chain
            chain = nil
            Task { await c?.close() }
            return
        }
        errorMessage = "\(error)"
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        guard let s = await ensureSession() else { return }
        do {
            containers = try await DockerService.list(over: s)
            errorMessage = nil
        } catch {
            handleSessionFailure(error, session: s)
        }
    }

    func act(_ kind: DockerAction, on ref: String) async {
        guard let s = await ensureSession() else { return }
        busyRefs.insert(ref)
        defer { busyRefs.remove(ref) }
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

    func fetchLogs(_ ref: String) async -> String {
        guard let s = await ensureSession() else { return "(ingen anslutning)" }
        do { return try await DockerService.logs(ref, tail: 200, over: s) }
        catch {
            handleSessionFailure(error, session: s)
            return "Fel: \(error)"
        }
    }

    func disconnect() {
        // Sätts FÖRE cancel/städning: en `act()`/`refresh()` som redan är
        // förbi `ensureSession()` och fortfarande kör kan annars racea in en
        // ny anslutning genom `ensureSession()` efter att den här metoden
        // returnerat (se kommentaren vid `isTornDown`-fältet).
        isTornDown = true
        // Avbryter en ev. pågående anslutning — annars kan den hinna klart
        // EFTER städningen nedan och skriva tillbaka en levande chain som
        // aldrig stängs (samma CodeRabbit-mönster som SFTPBrowserModel, PR #172).
        connectingTask?.cancel()
        let c = chain
        chain = nil
        Task { await c?.close() }
    }
}

struct LogRef: Identifiable { let id: String }

struct DockerView: View {
    @StateObject private var model: DockerModel
    @State private var logRef: LogRef?
    @State private var shellRequest: ConnectRequest?
    private let request: ConnectRequest
    /// Vidarebefordras till `SessionView` för jump-host-uppslagning när en
    /// container-shell öppnas. `nil` om anropsplatsen saknar en delad store
    /// (se `SessionView.store`).
    let store: HostStore?

    init(request: ConnectRequest, store: HostStore? = nil) {
        self.request = request
        self.store = store
        _model = StateObject(wrappedValue: DockerModel(request: request, store: store))
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
        .navInlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { await model.refresh() }
        .onDisappear { model.disconnect() }
        .sheet(item: $logRef) { ref in
            LogsSheet(title: ref.id, load: { await model.fetchLogs(ref.id) })
        }
        .cover(item: $shellRequest) { req in SessionView(request: req, store: store) }
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
                    Button { logRef = LogRef(id: c.name) } label: { Label("Logg", systemImage: "doc.plaintext") }
                    if c.isRunning, let cmd = try? DockerService.execShellCommand(c.name) {
                        Button { shellRequest = request.running(cmd) } label: {
                            Label("Shell", systemImage: "terminal")
                        }
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

/// Visar logg-utdrag för en container. Monospace, scrollbar.
struct LogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let load: () async -> String
    @State private var text = "Hämtar…"

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Klar") { dismiss() } }
            }
            .task { text = await load() }
        }
    }
}
#endif
