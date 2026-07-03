#if canImport(SwiftUI)
import SwiftUI
import SSHCore

enum DockerAction { case start, stop, restart }

@MainActor
final class DockerModel: ObservableObject {
    @Published var containers: [DockerContainer] = []
    @Published var errorMessage: String?
    @Published var loading = false
    @Published var busyRef: String?
    private let request: ConnectRequest
    private var session: SSHSession?
    // Cachar det pågående anslutningsförsöket så samtidiga anrop (t.ex.
    // refresh() och act() strax efter varandra, innan connect() svarat) väntar
    // in samma försök i stället för att skapa varsin SSHSession var.
    private var connectingTask: Task<SSHSession?, Never>?

    init(request: ConnectRequest) { self.request = request }

    private func ensureSession() async -> SSHSession? {
        if let s = session { return s }
        if let connectingTask { return await connectingTask.value }

        // Skapad inifrån en @MainActor-metod (inte .detached), så den ärver
        // MainActor-isoleringen — säkert att sätta errorMessage direkt här.
        let task = Task<SSHSession?, Never> { [weak self] in
            guard let self else { return nil }
            guard let auth = resolveAuth(for: self.request.host, password: self.request.password) else {
                self.errorMessage = "Kan inte autentisera värden."
                return nil
            }
            let s = SSHSession(target: self.request.host.target, auth: auth)
            do {
                try await s.connect()
                return s
            } catch {
                self.errorMessage = "\(error)"
                return nil
            }
        }
        connectingTask = task
        let result = await task.value
        connectingTask = nil
        session = result
        return result
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        guard let s = await ensureSession() else { return }
        do {
            containers = try await DockerService.list(over: s)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    func act(_ kind: DockerAction, on ref: String) async {
        guard let s = await ensureSession() else { return }
        busyRef = ref
        defer { busyRef = nil }
        do {
            switch kind {
            case .start: try await DockerService.start(ref, over: s)
            case .stop: try await DockerService.stop(ref, over: s)
            case .restart: try await DockerService.restart(ref, over: s)
            }
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func fetchLogs(_ ref: String) async -> String {
        guard let s = await ensureSession() else { return "(ingen anslutning)" }
        do { return try await DockerService.logs(ref, tail: 200, over: s) }
        catch { return "Fel: \(error)" }
    }

    func disconnect() {
        let s = session
        session = nil
        Task { await s?.close() }
    }
}

struct LogRef: Identifiable { let id: String }

struct DockerView: View {
    @StateObject private var model: DockerModel
    @State private var logRef: LogRef?
    @State private var shellRequest: ConnectRequest?
    private let request: ConnectRequest

    init(request: ConnectRequest) {
        self.request = request
        _model = StateObject(wrappedValue: DockerModel(request: request))
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
        .cover(item: $shellRequest) { req in SessionView(request: req) }
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
            if model.busyRef == c.name {
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
