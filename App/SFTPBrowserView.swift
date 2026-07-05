#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// SFTP-filhanterare — bläddra, skapa mapp, döp om, ta bort. Fas D i
/// ROADMAP.md. Förhandsvisning/textredigering/Drag & Drop/chmod/Zip-Tar är
/// medvetet uppskjutet till ett senare steg; det här är den första,
/// användbara versionen (motsvarar en enkel Finder/Files-lista).
struct SFTPBrowserView: View {
    @StateObject private var model: SFTPBrowserModel
    @State private var renaming: SFTPNameEntry?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""

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
            }
        }
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
        .disabled(!isDir)
        .buttonStyle(.plain)
    }
}
#endif
