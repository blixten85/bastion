#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// SFTP-filhanterare — bläddra, skapa mapp, döp om, ta bort, redigera
/// textfiler, chmod/chown, komprimera/packa upp (.tar.gz/.zip). Fas D i
/// ROADMAP.md. Förhandsvisning/Drag & Drop är fortfarande medvetet
/// uppskjutet.
struct SFTPBrowserView: View {
    /// EN sheet-presentatör för chmod/chown/komprimera — inte tre separata
    /// `.sheet(isPresented:)` på samma vy. Lärdom från S3-lagringsvyns
    /// CodeRabbit-fynd (#119) applicerad proaktivt här: SwiftUI garanterar
    /// bara att den SISTA av flera sådana faktiskt presenteras
    /// tillförlitligt.
    private enum ActiveFileAction: Identifiable {
        case chmod(SFTPNameEntry)
        case chown(SFTPNameEntry)
        case compress(SFTPNameEntry)

        var id: String {
            switch self {
            case .chmod(let e): return "chmod-\(e.filename)"
            case .chown(let e): return "chown-\(e.filename)"
            case .compress(let e): return "compress-\(e.filename)"
            }
        }
    }

    @StateObject private var model: SFTPBrowserModel
    @State private var renaming: SFTPNameEntry?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var activeFileAction: ActiveFileAction?

    init(request: ConnectRequest) {
        _model = StateObject(wrappedValue: SFTPBrowserModel(request: request))
    }

    var body: some View {
        Group {
            if let e = model.errorMessage {
                ContentUnavailableView("Något gick fel", systemImage: "exclamationmark.triangle",
                                       description: Text(e))
            } else if model.loading && model.entries.isEmpty {
                ProgressView()
            } else if model.entries.isEmpty {
                ContentUnavailableView("Tom mapp", systemImage: "folder")
            } else {
                list
            }
        }
        .navigationTitle(model.currentPath == "." ? "/" : model.currentPath)
        .navInlineTitle()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { Task { await model.navigateUp() } } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!model.canNavigateUp)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { newFolderName = ""; showNewFolder = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { await model.refresh() }
        .onDisappear { model.disconnect() }
        .alert("Ny mapp", isPresented: $showNewFolder) {
            TextField("Namn", text: $newFolderName).noAutocap().autocorrectionDisabled()
            Button("Skapa") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await model.createDirectory(named: name) }
            }
            Button("Avbryt", role: .cancel) {}
        }
        .alert("Döp om", isPresented: .constant(renaming != nil)) {
            TextField("Namn", text: $renameText).noAutocap().autocorrectionDisabled()
            Button("Spara") {
                if let entry = renaming {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { Task { await model.rename(entry, to: name) } }
                }
                renaming = nil
            }
            Button("Avbryt", role: .cancel) { renaming = nil }
        }
        .sheet(item: $model.editingFile) { file in
            SFTPFileEditorView(
                file: file,
                onSave: { newContent in
                    model.editingFile?.content = newContent
                    Task { await model.saveEditingFile() }
                },
                onCancel: { model.editingFile = nil }
            )
        }
        .sheet(item: $activeFileAction) { action in
            switch action {
            case .chmod(let entry):
                ChmodSheet(entry: entry, onSave: { mode in
                    activeFileAction = nil
                    Task { await model.chmod(entry, mode: mode) }
                }, onCancel: { activeFileAction = nil })
            case .chown(let entry):
                ChownSheet(entry: entry, onSave: { uid, gid in
                    activeFileAction = nil
                    Task { await model.chown(entry, uidText: uid, gidText: gid) }
                }, onCancel: { activeFileAction = nil })
            case .compress(let entry):
                CompressSheet(entry: entry, onCreate: { name, useZip in
                    activeFileAction = nil
                    Task { await model.compress(entry, archiveName: name, useZip: useZip) }
                }, onCancel: { activeFileAction = nil })
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.sortedEntries, id: \.filename) { entry in
                row(entry)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await model.delete(entry) } } label: {
                            Label("Ta bort", systemImage: "trash")
                        }
                        Button {
                            renameText = entry.filename
                            renaming = entry
                        } label: {
                            Label("Döp om", systemImage: "pencil")
                        }.tint(.blue)
                    }
                    .contextMenu {
                        Button { activeFileAction = .chmod(entry) } label: {
                            Label("Ändra behörighet (chmod)", systemImage: "lock.shield")
                        }
                        Button { activeFileAction = .chown(entry) } label: {
                            Label("Ändra ägare (chown)", systemImage: "person.badge.key")
                        }
                        Button { activeFileAction = .compress(entry) } label: {
                            Label("Komprimera", systemImage: "archivebox")
                        }
                        if isArchive(entry.filename) {
                            Button { Task { await model.extract(entry) } } label: {
                                Label("Packa upp", systemImage: "shippingbox")
                            }
                        }
                    }
            }
        }
    }

    private func isArchive(_ filename: String) -> Bool {
        filename.hasSuffix(".tar.gz") || filename.hasSuffix(".tgz") || filename.hasSuffix(".zip")
    }

    private func row(_ entry: SFTPNameEntry) -> some View {
        let isDir = entry.attributes.isDirectory
        return Button {
            Task { await model.open(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isDir ? "folder.fill" : "doc")
                    .foregroundStyle(isDir ? .blue : .secondary)
                    .frame(width: 24)
                Text(entry.filename)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                if !isDir, let size = entry.attributes.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Egen vy (inte bara en beräknad `body`-egenskap) eftersom den behöver sin
/// egen `@State` för det redigerbara innehållet, initierat från parametrar —
/// samma mönster som S3-lagringsvyns `S3ObjectViewerSheet`.
private struct SFTPFileEditorView: View {
    let file: SFTPBrowserModel.EditingFile
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var content: String

    init(file: SFTPBrowserModel.EditingFile, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.file = file
        self.onSave = onSave
        self.onCancel = onCancel
        self._content = State(wrappedValue: file.content)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if file.isBinary {
                    Text("Skrivskyddat — binärt innehåll kan inte redigeras och sparas som text.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding()
                }
                TextEditor(text: $content)
                    .disabled(file.isBinary)
                    .font(.system(.footnote, design: .monospaced))
                    .noAutocap().autocorrectionDisabled()
                    .padding(file.isBinary ? [.horizontal, .bottom] : .all)
            }
            .navigationTitle((file.path as NSString).lastPathComponent)
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Stäng") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") { onSave(content) }
                        .disabled(file.isBinary)
                }
            }
        }
    }
}

private struct ChmodSheet: View {
    let entry: SFTPNameEntry
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var mode = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Behörighet (t.ex. 644)", text: $mode)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            .navigationTitle("chmod: \(entry.filename)")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") {
                        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSave(trimmed)
                    }
                    .disabled(mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ChownSheet: View {
    let entry: SFTPNameEntry
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var uidText = ""
    @State private var gidText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("UID (t.ex. 1000)", text: $uidText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                TextField("GID (t.ex. 1000)", text: $gidText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            .navigationTitle("chown: \(entry.filename)")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") {
                        let uid = uidText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let gid = gidText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !uid.isEmpty, !gid.isEmpty else { return }
                        onSave(uid, gid)
                    }
                    .disabled(uidText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || gidText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct CompressSheet: View {
    let entry: SFTPNameEntry
    let onCreate: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var archiveName: String
    @State private var useZip = false

    init(entry: SFTPNameEntry, onCreate: @escaping (String, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.onCreate = onCreate
        self.onCancel = onCancel
        self._archiveName = State(wrappedValue: entry.filename + ".tar.gz")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Arkivnamn", text: $archiveName)
                    .noAutocap().autocorrectionDisabled()
                Toggle("Zip (istället för tar.gz)", isOn: $useZip)
            }
            .navigationTitle("Komprimera: \(entry.filename)")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Skapa") {
                        let trimmed = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onCreate(trimmed, useZip)
                    }
                    .disabled(archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif
