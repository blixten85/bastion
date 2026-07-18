#if canImport(SwiftUI)
import SwiftUI
import Foundation
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
    /// För att slå upp en ev. jump-host, se `resolveConnectionPlan`. `nil`
    /// på anropsplatser utan delad store — ansluter då direkt.
    private let store: HostStore?
    private var chain: SSHConnectionChain?
    private var sftp: SFTPClient?
    private var connectingTask: Task<SFTPClient?, Never>?

    /// Target-sessionen i den aktiva kedjan — samma anropskontrakt som
    /// tidigare (`ArchiveOperations` m.fl. kör alltid mot target, aldrig
    /// jump-hoppet).
    private var session: SSHSession? { chain?.target }

    init(request: ConnectRequest, store: HostStore? = nil) {
        self.request = request
        self.store = store
    }

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
            guard let plan = resolveConnectionPlan(for: self.request.host, password: self.request.password, store: self.store) else {
                self.errorMessage = "Kan inte autentisera värden (eller dess jump-host, om en är vald)."
                return nil
            }
            do {
                let c = try await SSHConnectionChain.connect(
                    target: self.request.host.target, targetAuth: plan.auth, jump: plan.jump)
                let client = try await SFTPClient.open(on: c.target)
                // disconnect() kan ha körts (vyn stängd) medan vi väntade på
                // connect()/open — utan den här kollen skulle vi återuppliva
                // self.chain/self.sftp EFTER att disconnect() redan städat,
                // och den nya anslutningen skulle aldrig stängas (CodeRabbit-
                // fynd, PR #48).
                guard !Task.isCancelled else {
                    await client.close()
                    await c.close()
                    return nil
                }
                // self.sftp sätts HÄR, tillsammans med self.chain, inte av
                // anroparen efter att task.value returnerat — annars finns
                // ett fönster där disconnect() hinner köra (chain redan
                // satt av oss, men sftp fortfarande nil ur anroparens
                // perspektiv) mellan att tasken returnerar och anroparen
                // skriver tillbaka sftp, vilket skulle skriva över
                // disconnect()s städning med en redan stängd klient
                // (CodeRabbit-fynd, PR #50).
                self.chain = c
                self.sftp = client
                return client
            } catch {
                // Om connect() lyckades men SFTPClient.open(on:) kastade
                // (t.ex. subsystemet avvisat) sattes self.chain aldrig —
                // stäng den öppna anslutningen explicit, annars läcker den
                // tyst vid varje misslyckat SFTP-öppningsförsök (CodeRabbit-
                // fynd, PR #47). SSHConnectionChain.connect städar redan sina
                // egna fel innan den kastar, så inget extra att stänga här.
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

    /// Laddar upp en eller flera drag-and-drop:ade lokala filer/mappar till
    /// den katalog som VISAS just nu (`currentPath`) — anslutningen som
    /// redan hålls öppen av `ensureClient()` medan man bläddrar återanvänds
    /// rakt av, ingen ny session öppnas. Mappar laddas upp REKURSIVT.
    func uploadDropped(_ urls: [URL]) async {
        for url in urls {
            await uploadOne(url)
        }
        await refresh()
    }

    private func uploadOne(_ localURL: URL) async {
        // macOS App Sandbox ger tillfällig läsbehörighet för drag-and-drop-
        // ade filer/mappar UTAN egen entitlement (samma undantag som en
        // NSOpenPanel-vald fil), men bara mellan start/stop-anropen.
        let accessing = localURL.startAccessingSecurityScopedResource()
        defer { if accessing { localURL.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            errorMessage = "Hittar inte \(localURL.lastPathComponent)."
            return
        }

        let remotePath = joined(localURL.lastPathComponent)
        if isDirectory.boolValue {
            await uploadDirectory(localURL, remotePath: remotePath)
        } else {
            await uploadFile(localURL, remotePath: remotePath)
        }
    }

    private func uploadFile(_ localURL: URL, remotePath: String) async {
        guard let client = await ensureClient() else { return }
        do {
            let data = try Data(contentsOf: localURL)
            try await client.writeFile(remotePath, data: Array(data))
        } catch {
            errorMessage = "\(localURL.lastPathComponent): \(error)"
        }
    }

    /// `mkdir`-fel ignoreras medvetet — SFTP version 3 (den version den
    /// här klienten talar) har ingen egen "finns redan"-statuskod (den
    /// kom först i v6), så ett fel HÄR kan lika gärna betyda "mappen
    /// finns redan" (ofarligt vid omuppladdning) som ett riktigt problem —
    /// då misslyckas ändå filuppladdningarna in i den mappen nedan, med
    /// sitt eget tydliga fel per fil.
    private func uploadDirectory(_ localURL: URL, remotePath: String) async {
        guard let client = await ensureClient() else { return }
        try? await client.mkdir(remotePath)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: localURL, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            errorMessage = "Kunde inte läsa mappen \(localURL.lastPathComponent)."
            return
        }
        for entry in entries {
            let childRemotePath = remotePath + "/" + entry.lastPathComponent
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                await uploadDirectory(entry, remotePath: childRemotePath)
            } else {
                await uploadFile(entry, remotePath: childRemotePath)
            }
        }
    }

    func disconnect() {
        // Avbryter en ev. pågående anslutning — annars kan den hinna klart
        // EFTER städningen nedan och skriva tillbaka ett levande session/
        // sftp som aldrig stängs (CodeRabbit-fynd, PR #48).
        connectingTask?.cancel()
        let ch = chain
        let c = sftp
        chain = nil
        sftp = nil
        Task {
            await c?.close()
            await ch?.close()
        }
    }
}
#endif
