#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Håller SFTP-anslutningen och den aktuella katalogvyn — samma
/// anslutnings-livscykelmönster som `DockerModel` (lazy connect, cachar
/// pågående anslutningsförsök så samtidiga anrop inte startar varsin
/// session/kanal).
@MainActor
final class SFTPBrowserModel: ObservableObject {
    @Published var currentPath: String = "."
    @Published var entries: [SFTPNameEntry] = []
    @Published var errorMessage: String?
    @Published var loading = false

    private let request: ConnectRequest
    private var session: SSHSession?
    private var sftp: SFTPClient?
    private var connectingTask: Task<SFTPClient?, Never>?

    init(request: ConnectRequest) { self.request = request }

    /// Katalogen visas alltid mapp-först, sedan alfabetiskt inom varje grupp.
    var sortedEntries: [SFTPNameEntry] {
        entries.sorted { a, b in
            if a.attributes.isDirectory != b.attributes.isDirectory {
                return a.attributes.isDirectory
            }
            return a.filename.lowercased() < b.filename.lowercased()
        }
    }

    private func ensureClient() async -> SFTPClient? {
        if let sftp { return sftp }
        if let connectingTask { return await connectingTask.value }

        let task = Task<SFTPClient?, Never> { [weak self] in
            guard let self else { return nil }
            guard let auth = resolveAuth(for: self.request.host, password: self.request.password) else {
                self.errorMessage = "Kan inte autentisera värden."
                return nil
            }
            let s = SSHSession(target: self.request.host.target, auth: auth)
            do {
                try await s.connect()
                let client = try await SFTPClient.open(on: s)
                self.session = s
                return client
            } catch {
                // Om connect() lyckades men SFTPClient.open(on:) kastade
                // (t.ex. subsystemet avvisat) sattes self.session aldrig —
                // stäng den öppna anslutningen explicit, annars läcker den
                // tyst vid varje misslyckat SFTP-öppningsförsök (CodeRabbit-
                // fynd, PR #47).
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
        loading = true
        defer { loading = false }
        guard let client = await ensureClient() else { return }
        do {
            entries = try await client.listDirectory(currentPath)
                .filter { $0.filename != "." && $0.filename != ".." }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func joined(_ name: String) -> String {
        currentPath == "." ? name : currentPath + "/" + name
    }

    func open(_ entry: SFTPNameEntry) async {
        guard entry.attributes.isDirectory else { return }
        currentPath = joined(entry.filename)
        await refresh()
    }

    var canNavigateUp: Bool { currentPath != "." }

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
#endif
