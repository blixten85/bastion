import Foundation
import SSHCore
import SwiftCrossUI

/// SFTP-filhanterare — motsvarar `App/SFTPBrowserView.swift` +
/// `App/SFTPBrowserModel.swift`. Samma lazy-connect-mönster som
/// `DockerModel`/`SnippetListModel` här. Ingen swipe-actions eller
/// tappbar rad i SwiftCrossUI, så åtgärder körs via knappar under
/// listan istället, styrda av `List`s obligatoriska selection-binding.
@MainActor
final class SFTPBrowserModel: ObservableObject {
    @Published var currentPath = "."
    @Published var entries: [SFTPNameEntry] = []
    @Published var errorMessage: String?

    private let host: Host
    private let password: String?
    private var session: SSHSession?
    private var sftp: SFTPClient?
    private var connectingTask: Task<SFTPClient?, Never>?

    init(host: Host, password: String?) {
        self.host = host
        self.password = password
    }

    var sortedEntries: [SFTPNameEntry] {
        entries.sorted { a, b in
            if a.attributes.isDirectory != b.attributes.isDirectory { return a.attributes.isDirectory }
            return a.filename.lowercased() < b.filename.lowercased()
        }
    }

    var canNavigateUp: Bool { currentPath != "." }

    private func joined(_ name: String) -> String {
        currentPath == "." ? name : currentPath + "/" + name
    }

    private func ensureClient() async -> SFTPClient? {
        if let sftp { return sftp }
        if let connectingTask { return await connectingTask.value }

        let task = Task<SFTPClient?, Never> { [weak self] in
            guard let self else { return nil }
            guard let auth = resolveAuth(for: self.host, password: self.password) else {
                self.errorMessage = "Kan inte autentisera värden."
                return nil
            }
            let s = SSHSession(target: self.host.target, auth: auth)
            do {
                try await s.connect()
                let client = try await SFTPClient.open(on: s)
                // disconnect() kan ha körts (vyn stängd) medan vi väntade på
                // connect()/open — utan den här kollen skulle vi återuppliva
                // self.session/self.sftp EFTER att disconnect() redan städat,
                // och den nya anslutningen skulle aldrig stängas (CodeRabbit-
                // fynd, PR #48).
                guard !Task.isCancelled else {
                    await client.close()
                    await s.close()
                    return nil
                }
                self.session = s
                return client
            } catch {
                // Samma läcka som i App/SFTPBrowserModel.swift: om connect()
                // lyckades men SFTPClient.open(on:) kastade sattes
                // self.session aldrig — stäng den öppna anslutningen explicit
                // (CodeRabbit-fynd, PR #47).
                await s.close()
                self.errorMessage = "\(error)"
                return nil
            }
        }
        connectingTask = task
        let result = await task.value
        connectingTask = nil
        sftp = result
        return result
    }

    func refresh() async {
        guard let client = await ensureClient() else { return }
        do {
            entries = try await client.listDirectory(currentPath)
                .filter { $0.filename != "." && $0.filename != ".." }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    func open(_ entry: SFTPNameEntry) async {
        guard entry.attributes.isDirectory else { return }
        currentPath = joined(entry.filename)
        await refresh()
    }

    func navigateUp() async {
        guard canNavigateUp else { return }
        if let slash = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[currentPath.startIndex..<slash])
        } else {
            currentPath = "."
        }
        await refresh()
    }

    func delete(_ entry: SFTPNameEntry) async {
        guard let client = await ensureClient() else { return }
        let path = joined(entry.filename)
        do {
            if entry.attributes.isDirectory {
                try await client.rmdir(path)
            } else {
                try await client.remove(path)
            }
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func createDirectory(named name: String) async {
        guard let client = await ensureClient() else { return }
        do {
            try await client.mkdir(joined(name))
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func rename(_ entry: SFTPNameEntry, to newName: String) async {
        guard let client = await ensureClient() else { return }
        do {
            try await client.rename(joined(entry.filename), to: joined(newName))
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func disconnect() {
        // Avbryter en ev. pågående anslutning — annars kan den hinna klart
        // EFTER städningen nedan och skriva tillbaka ett levande session/
        // sftp som aldrig stängs (CodeRabbit-fynd, PR #48).
        connectingTask?.cancel()
        let s = session
        let c = sftp
        session = nil
        sftp = nil
        Task {
            await c?.close()
            await s?.close()
        }
    }
}

struct SFTPBrowserView: View {
    @State private var model: SFTPBrowserModel
    @State private var selectedFilename: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showRename = false
    @State private var renameText = ""

    init(host: Host, password: String?) {
        self._model = State(wrappedValue: SFTPBrowserModel(host: host, password: password))
    }

    private var selectedEntry: SFTPNameEntry? {
        model.entries.first { $0.filename == selectedFilename }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filer: \(model.currentPath == "." ? "/" : model.currentPath)").font(.title2)
                Spacer()
                Button("Upp") { Task { await model.navigateUp() } }
                Button("Ny mapp") { newFolderName = ""; showNewFolder = true }
                Button("Uppdatera") { Task { await model.refresh() } }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage).foregroundColor(.red)
            }

            if showNewFolder {
                HStack {
                    TextField("Mappnamn", text: $newFolderName)
                    Button("Skapa") {
                        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                        showNewFolder = false
                        guard !name.isEmpty else { return }
                        Task { await model.createDirectory(named: name) }
                    }
                    Button("Avbryt") { showNewFolder = false }
                }
            }

            if model.entries.isEmpty {
                Text("Tom mapp.").foregroundColor(.gray)
            } else {
                List(model.sortedEntries, id: \.filename, selection: $selectedFilename) { entry in
                    HStack {
                        Text(entry.attributes.isDirectory ? "📁 \(entry.filename)" : "📄 \(entry.filename)")
                        Spacer()
                        if !entry.attributes.isDirectory, let size = entry.attributes.size {
                            Text("\(size) B").foregroundColor(.gray)
                        }
                    }
                }
            }

            if let selected = selectedEntry {
                if showRename {
                    HStack {
                        TextField("Nytt namn", text: $renameText)
                        Button("Spara") {
                            let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            showRename = false
                            guard !name.isEmpty else { return }
                            Task { await model.rename(selected, to: name) }
                        }
                        Button("Avbryt") { showRename = false }
                    }
                } else {
                    HStack {
                        if selected.attributes.isDirectory {
                            Button("Öppna") { Task { await model.open(selected) } }
                        }
                        Button("Döp om") { renameText = selected.filename; showRename = true }
                        Button("Ta bort") { Task { await model.delete(selected) } }
                    }
                }
            }
        }
        .padding()
        .task { await model.refresh() }
        // Utan detta kan ett filnamn från FÖREGÅENDE mapp råka matcha ett
        // likadant namn i den nya mappen efter navigering och visa fel
        // "vald post" — samma buggklass som CodeRabbit fann i Snippets/
        // Kommandobiblioteket (PR #34), fixad proaktivt här direkt.
        .onChange(of: model.currentPath) { selectedFilename = nil }
        // Samma mönster som DockerView.swift — utan detta stängs aldrig den
        // underliggande SSH/SFTP-anslutningen när arket stängs (CodeRabbit-
        // fynd, PR #47).
        .onDisappear { model.disconnect() }
    }
}
