#if canImport(SwiftUI)
import SwiftUI
import SSHCore

@MainActor
final class S3ConnectionListModel: ObservableObject {
    private let store = S3ConnectionStore()
    @Published var connections: [S3Connection] = []

    init() { reload() }
    func reload() { connections = store.all() }
    func save(_ connection: S3Connection) { store.upsert(connection); reload() }
    func delete(_ connection: S3Connection) { store.delete(connection.id); reload() }
}

/// Innehållet skickas som text (klistra in/redigera) — samma pragmatiska
/// v1-avgränsning som WireGuard-profilernas råtextredigering: binärt
/// innehåll är inte målet för v1 (konfigfiler, loggar, README:er osv. är
/// de rimliga första användningsfallen för en objektlagringsvy).
@MainActor
final class S3BrowserModel: ObservableObject {
    enum Level {
        case buckets
        case objects(bucket: String)
    }
    @Published var level: Level = .buckets
    @Published var buckets: [S3Bucket] = []
    @Published var objects: [S3Object] = []
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let client: S3Client

    init(connection: S3Connection) {
        client = S3Client(
            endpoint: connection.endpointURL ?? URL(string: "https://localhost")!,
            region: connection.region, credentials: connection.credentials)
    }

    func loadBuckets() async {
        isLoading = true
        errorMessage = nil
        do { buckets = try await client.listBuckets() } catch { errorMessage = "\(error)" }
        isLoading = false
    }

    func createBucket(_ name: String) async {
        do {
            try await client.createBucket(name)
            await loadBuckets()
        } catch { errorMessage = "\(error)" }
    }

    func deleteBucket(_ name: String) async {
        do {
            try await client.deleteBucket(name)
            await loadBuckets()
        } catch { errorMessage = "\(error)" }
    }

    func openBucket(_ name: String) async {
        level = .objects(bucket: name)
        await loadObjects(bucket: name)
    }

    func loadObjects(bucket: String) async {
        isLoading = true
        errorMessage = nil
        do { objects = try await client.listObjects(bucket: bucket) } catch { errorMessage = "\(error)" }
        isLoading = false
    }

    func upload(bucket: String, key: String, content: String) async {
        do {
            try await client.putObject(bucket: bucket, key: key, data: Data(content.utf8), contentType: "text/plain")
            await loadObjects(bucket: bucket)
        } catch { errorMessage = "\(error)" }
    }

    func download(bucket: String, key: String) async -> String? {
        do {
            let data = try await client.getObject(bucket: bucket, key: key)
            return String(data: data, encoding: .utf8) ?? "(binärt innehåll, \(data.count) bytes — kan inte visas som text)"
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    func deleteObject(bucket: String, key: String) async {
        do {
            try await client.deleteObject(bucket: bucket, key: key)
            await loadObjects(bucket: bucket)
        } catch { errorMessage = "\(error)" }
    }
}

/// Bläddra S3-kompatibel objektlagring: buckets -> objekt -> ladda upp/ner
/// (som text) / ta bort. v1-avgränsning: text-innehåll, inte godtyckliga
/// binärfiler — se modellens doc-kommentar.
struct S3BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: S3Connection

    @StateObject private var model: S3BrowserModel
    @State private var showNewBucket = false
    @State private var newBucketName = ""
    @State private var showUpload = false
    @State private var uploadKey = ""
    @State private var uploadContent = ""
    @State private var showViewer = false
    @State private var viewerKey: String?
    @State private var viewerContent = ""

    init(connection: S3Connection) {
        self.connection = connection
        self._model = StateObject(wrappedValue: S3BrowserModel(connection: connection))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error = model.errorMessage {
                    ScrollView { Text(error).foregroundStyle(.red).padding() }
                } else if model.isLoading {
                    ProgressView("Laddar…")
                } else {
                    content
                }
            }
            .navigationTitle(title)
            .navInlineTitle()
            .task { await model.loadBuckets() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Stäng") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    switch model.level {
                    case .buckets:
                        Button { newBucketName = ""; showNewBucket = true } label: {
                            Image(systemName: "plus")
                        }
                    case .objects:
                        Button { uploadKey = ""; uploadContent = ""; showUpload = true } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showNewBucket) { newBucketSheet }
            .sheet(isPresented: $showUpload) { uploadSheet }
            .sheet(isPresented: $showViewer) { viewerSheet }
        }
    }

    private var title: String {
        switch model.level {
        case .buckets: return connection.name
        case .objects(let bucket): return bucket
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.level {
        case .buckets:
            if model.buckets.isEmpty {
                ContentUnavailableView("Inga buckets än", systemImage: "archivebox")
            } else {
                List {
                    ForEach(model.buckets, id: \.name) { bucket in
                        Button { Task { await model.openBucket(bucket.name) } } label: {
                            Text(bucket.name)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { Task { await model.deleteBucket(bucket.name) } } label: {
                                Label("Ta bort", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        case .objects(let bucket):
            if model.objects.isEmpty {
                ContentUnavailableView("Inga objekt än", systemImage: "doc")
            } else {
                List {
                    ForEach(model.objects, id: \.key) { object in
                        Button { Task { await openViewer(bucket: bucket, key: object.key) } } label: {
                            HStack {
                                Text(object.key)
                                Spacer()
                                Text(Self.formatBytes(object.size)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.deleteObject(bucket: bucket, key: object.key) }
                            } label: {
                                Label("Ta bort", systemImage: "trash")
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        model.level = .buckets
                        Task { await model.loadBuckets() }
                    } label: {
                        Label("Tillbaka till buckets", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding()
                }
            }
        }
    }

    private func openViewer(bucket: String, key: String) async {
        if let text = await model.download(bucket: bucket, key: key) {
            viewerContent = text
            viewerKey = key
            showViewer = true
        }
    }

    private var newBucketSheet: some View {
        NavigationStack {
            Form {
                TextField("Namn", text: $newBucketName)
                    .noAutocap().autocorrectionDisabled()
            }
            .navigationTitle("Ny bucket")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { showNewBucket = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Skapa") {
                        let name = newBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        Task { await model.createBucket(name) }
                        showNewBucket = false
                    }
                    .disabled(newBucketName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var uploadSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nyckel (t.ex. mapp/fil.txt)", text: $uploadKey)
                        .noAutocap().autocorrectionDisabled()
                }
                Section("Innehåll") {
                    TextEditor(text: $uploadContent)
                        .frame(minHeight: 220)
                        .font(.system(.footnote, design: .monospaced))
                        .noAutocap().autocorrectionDisabled()
                }
            }
            .navigationTitle("Ladda upp objekt")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { showUpload = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ladda upp") {
                        guard case .objects(let bucket) = model.level else { return }
                        let key = uploadKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        Task { await model.upload(bucket: bucket, key: key, content: uploadContent) }
                        showUpload = false
                    }
                    .disabled(uploadKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var viewerSheet: some View {
        NavigationStack {
            TextEditor(text: $viewerContent)
                .font(.system(.footnote, design: .monospaced))
                .noAutocap().autocorrectionDisabled()
                .padding()
                .navigationTitle(viewerKey ?? "")
                .navInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Stäng") { showViewer = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Spara ändringar") {
                            guard case .objects(let bucket) = model.level, let key = viewerKey else { return }
                            Task { await model.upload(bucket: bucket, key: key, content: viewerContent) }
                            showViewer = false
                        }
                    }
                }
        }
    }

    static func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
    }
}

/// Toppnivåsheet: lista sparade S3-anslutningar, lägg till/ändra/ta bort,
/// öppna en för att bläddra. Motsvarar `WireGuardProfileListView` för
/// S3-kompatibel objektlagring.
struct S3ConnectionListView: View {
    @StateObject private var model = S3ConnectionListModel()
    @State private var editingConnection: S3Connection?
    @State private var browsingConnection: S3Connection?

    var body: some View {
        NavigationStack {
            Group {
                if model.connections.isEmpty {
                    ContentUnavailableView("Inga sparade anslutningar än", systemImage: "externaldrive.badge.icloud",
                                           description: Text("S3-kompatibel objektlagring (AWS S3, Hostup, MinIO, Ceph RGW m.fl.) — egna nycklar, inget OAuth."))
                } else {
                    List {
                        ForEach(model.connections) { connection in
                            Button { browsingConnection = connection } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.name).font(.body.weight(.medium))
                                    Text("\(connection.endpoint) · \(connection.region)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { model.delete(connection) } label: {
                                    Label("Ta bort", systemImage: "trash")
                                }
                                Button { editingConnection = connection } label: {
                                    Label("Ändra", systemImage: "pencil")
                                }.tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("S3-lagring")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingConnection = S3Connection(
                            name: "", endpoint: "", region: "us-east-1", accessKeyID: "", secretAccessKey: "")
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editingConnection) { connection in
                S3ConnectionEditView(
                    connection: connection,
                    onSave: { model.save($0); editingConnection = nil },
                    onCancel: { editingConnection = nil }
                )
            }
            .sheet(item: $browsingConnection) { connection in
                S3BrowserView(connection: connection)
            }
        }
    }
}

/// Redigerar en `S3Connection` fält-för-fält (till skillnad från WireGuards
/// råtextredigering — en S3-anslutning har inte en naturlig "klistra in
/// hela filen"-motsvarighet, användaren har separata värden: endpoint,
/// region, åtkomstnyckel, hemlig nyckel).
struct S3ConnectionEditView: View {
    let connection: S3Connection
    let onSave: (S3Connection) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var endpoint: String
    @State private var region: String
    @State private var accessKeyID: String
    @State private var secretAccessKey: String

    init(connection: S3Connection, onSave: @escaping (S3Connection) -> Void, onCancel: @escaping () -> Void) {
        self.connection = connection
        self.onSave = onSave
        self.onCancel = onCancel
        self._name = State(wrappedValue: connection.name)
        self._endpoint = State(wrappedValue: connection.endpoint)
        self._region = State(wrappedValue: connection.region)
        self._accessKeyID = State(wrappedValue: connection.accessKeyID)
        self._secretAccessKey = State(wrappedValue: connection.secretAccessKey)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: endpoint) != nil
            && !accessKeyID.isEmpty
            && !secretAccessKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Namn", text: $name)
                TextField("Endpoint (t.ex. https://s3.hostup.se)", text: $endpoint)
                    .noAutocap().autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                TextField("Region (t.ex. us-east-1)", text: $region)
                    .noAutocap().autocorrectionDisabled()
                TextField("Åtkomstnyckel (Access Key ID)", text: $accessKeyID)
                    .noAutocap().autocorrectionDisabled()
                SecureField("Hemlig nyckel (Secret Access Key)", text: $secretAccessKey)
            }
            .navigationTitle("S3-anslutning")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") {
                        var updated = connection
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.endpoint = endpoint
                        updated.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.accessKeyID = accessKeyID
                        updated.secretAccessKey = secretAccessKey
                        onSave(updated)
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
#endif
