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
    @Published var editingFile: EditingFile?

    struct EditingFile: Identifiable, Equatable {
        let path: String
        var content: String
        /// Data gick inte att avkoda som UTF8 — spara MÅSTE vara avstängt
        /// för det här fallet (samma lärdom som S3-lagringsvyn, #119: annars
        /// skriver "Spara" tyst över det riktiga binära innehållet med en
        /// platshållarsträng).
        let isBinary: Bool
        var id: String { path }
    }

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
                // self.sftp sätts HÄR, tillsammans med self.session, inte av
                // anroparen efter att task.value returnerat — annars finns
                // ett fönster där disconnect() hinner köra (session redan
                // satt av oss, men sftp fortfarande nil ur anroparens
                // perspektiv) mellan att tasken returnerar och anroparen
                // skriver tillbaka sftp, vilket skulle skriva över
                // disconnect()s städning med en redan stängd klient
                // (CodeRabbit-fynd, PR #50).
                self.session = s
                self.sftp = client
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
        if entry.attributes.isDirectory {
            currentPath = joined(entry.filename)
            await refresh()
            return
        }
        guard let client = await ensureClient() else { return }
        let path = joined(entry.filename)
        do {
            let bytes = try await client.readFile(path)
            if let text = String(bytes: bytes, encoding: .utf8) {
                editingFile = EditingFile(path: path, content: text, isBinary: false)
            } else {
                editingFile = EditingFile(
                    path: path,
                    content: "(binärt innehåll, \(bytes.count) bytes — kan inte visas eller redigeras som text)",
                    isBinary: true)
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func saveEditingFile() async {
        guard let file = editingFile, !file.isBinary else { return }
        guard let client = await ensureClient() else { return }
        do {
            try await client.writeFile(file.path, data: Array(file.content.utf8))
            editingFile = nil
        } catch {
            errorMessage = "\(error)"
        }
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

    /// `mode`: oktal sträng utan `0o`-prefix, t.ex. "644"/"755" — samma
    /// notation som `chmod` på kommandoraden, vilket är vad användaren
    /// redan känner till.
    func chmod(_ entry: SFTPNameEntry, mode: String) async {
        guard let value = UInt32(mode, radix: 8) else {
            errorMessage = "Ogiltig behörighet — ange tre oktala siffror, t.ex. 644."
            return
        }
        guard let client = await ensureClient() else { return }
        do {
            try await client.setPermissions(joined(entry.filename), mode: value)
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// `uidText`/`gidText`: NUMERISKA ID:n, inte användarnamn — SFTP
    /// version 3 känner bara till UID/GID, aldrig namn.
    func chown(_ entry: SFTPNameEntry, uidText: String, gidText: String) async {
        guard let uid = UInt32(uidText), let gid = UInt32(gidText) else {
            errorMessage = "Ogiltigt UID/GID — ange numeriska ID:n, t.ex. 1000."
            return
        }
        guard let client = await ensureClient() else { return }
        do {
            try await client.chown(joined(entry.filename), uid: uid, gid: gid)
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Komprimerar EN post (fil eller mapp) till ett nytt arkiv i samma
    /// katalog. `archiveName` bör sluta på `.tar.gz`/`.zip`.
    func compress(_ entry: SFTPNameEntry, archiveName: String, useZip: Bool) async {
        guard let client = await ensureClient(), let session else { return }
        do {
            // SFTP:s currentPath och exec-kanalens arbetskatalog delar
            // typiskt startkatalog men är INTE garanterat samma sak —
            // realpath slår upp den FAKTISKA absoluta sökvägen.
            let absoluteDir = try await client.realpath(currentPath)
            if useZip {
                try await ArchiveOperations.createZip(
                    paths: [entry.filename], archiveName: archiveName, in: absoluteDir, over: session)
            } else {
                try await ArchiveOperations.createTarGz(
                    paths: [entry.filename], archiveName: archiveName, in: absoluteDir, over: session)
            }
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Packar upp ett arkiv i SAMMA katalog det ligger i. Formatet avgörs
    /// av filändelsen — okänt format avvisas tydligt istället för att
    /// gissa fel kommando.
    func extract(_ entry: SFTPNameEntry) async {
        guard let client = await ensureClient(), let session else { return }
        do {
            let absoluteDir = try await client.realpath(currentPath)
            if entry.filename.hasSuffix(".tar.gz") || entry.filename.hasSuffix(".tgz") {
                try await ArchiveOperations.extractTarGz(archiveName: entry.filename, in: absoluteDir, over: session)
            } else if entry.filename.hasSuffix(".zip") {
                try await ArchiveOperations.extractZip(archiveName: entry.filename, in: absoluteDir, over: session)
            } else {
                errorMessage = "Okänt arkivformat — stödjer .tar.gz/.tgz/.zip."
                return
            }
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
#endif
