#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Delar host-databasen till vyerna och håller den observerbar.
@MainActor
final class HostListModel: ObservableObject {
    private let store = HostStore()
    @Published var hosts: [Host] = []

    init() { reload() }
    func reload() { hosts = store.all() }
    func save(_ host: Host) { store.upsert(host); reload() }
    func delete(_ host: Host) {
        if case .keychainKey(let id) = host.auth { Keychain.delete(id) }
        store.delete(host.id)
        reload()
    }
    func toggleFavorite(_ host: Host) {
        var h = host
        h.isFavorite.toggle()
        save(h)
    }

    @discardableResult
    func importConfig(_ text: String) -> Int {
        let n = store.importSSHConfig(text).count
        reload()
        return n
    }

    /// E2E-krypterad synkrunda mot den konfigurerade transporten (mapp eller ett kontointegrerat moln).
    func syncNow() async -> String {
        guard UserDefaults.standard.bool(forKey: SyncKeys.enabled) else { return "Sync är avstängd." }
        guard let pass = Keychain.get(SyncKeys.passphraseKey), !pass.isEmpty else {
            return "Ingen lösenfras angiven."
        }
        let transport = UserDefaults.standard.string(forKey: SyncKeys.transport) ?? "folder"

        func requireLogin(_ config: OAuthProviderConfig) -> String? {
            OAuthAccountManager.shared.isLoggedIn(config) ? nil : "Inte inloggad på \(config.displayName)."
        }

        let provider: SyncProvider
        switch transport {
        case "dropbox":
            if let err = requireLogin(OAuthProviders.dropbox) { return err }
            provider = DropboxSyncProvider(passphrase: pass)
        case "googledrive":
            if let err = requireLogin(OAuthProviders.googleDrive) { return err }
            provider = GoogleDriveSyncProvider(passphrase: pass)
        case "onedrive":
            if let err = requireLogin(OAuthProviders.oneDrive) { return err }
            provider = OneDriveSyncProvider(passphrase: pass)
        default:
            let folder = UserDefaults.standard.string(forKey: SyncKeys.folderPath) ?? ""
            guard !folder.isEmpty else { return "Ingen synkmapp vald." }
            let file = (folder as NSString).appendingPathComponent("bastion-sync.enc")
            provider = EncryptedFolderSyncProvider(path: file, passphrase: pass)
        }
        do {
            try store.sync(with: provider)
            reload()
            return "Synkat."
        } catch {
            return "Sync misslyckades: \(error.localizedDescription)"
        }
    }

    /// Grupperad efter tagg; otaggade hamnar under "Övriga". Favoriter får en
    /// egen sektion allra först och plockas ur sin vanliga taggsektion (annars
    /// skulle samma Host-id förekomma två gånger i samma List/ForEach, vilket
    /// SwiftUI inte diffar tillförlitligt).
    var groups: [(tag: String, hosts: [Host])] {
        var byTag: [String: [Host]] = [:]
        for h in hosts where !h.isFavorite {
            let tags = h.tags.isEmpty ? ["Övriga"] : h.tags
            for t in tags { byTag[t, default: []].append(h) }
        }
        let tagged = byTag.keys.sorted { $0.lowercased() < $1.lowercased() }
            .map { (tag: $0, hosts: byTag[$0]!.sorted { $0.alias.lowercased() < $1.alias.lowercased() }) }
        let favorites = hosts.filter(\.isFavorite).sorted { $0.alias.lowercased() < $1.alias.lowercased() }
        guard !favorites.isEmpty else { return tagged }
        return [(tag: "★ Favoriter", hosts: favorites)] + tagged
    }
}

/// Anslutningsbegäran: vald värd + eventuellt inmatat lösenord.
struct ConnectRequest: Identifiable {
    let id = UUID()
    let host: Host
    let password: String?
    /// Kommando att köra direkt i shellen (t.ex. `docker exec …`).
    var initialCommand: String? = nil

    /// Kopia som öppnar en shell med ett startkommando.
    func running(_ command: String) -> ConnectRequest {
        ConnectRequest(host: host, password: password, initialCommand: command)
    }
}

struct HostListView: View {
    @StateObject private var model = HostListModel()
    @State private var editing: Host?
    @State private var connecting: ConnectRequest?
    @State private var passwordFor: Host?
    @State private var passwordInput = ""
    @State private var showSettings = false
    @State private var showImport = false
    @State private var searchText = ""

    /// `model.groups` filtrerat på sökfältet (alias/hostname/user/taggar,
    /// case-insensitive); tomma sektioner (ingen träff i gruppen) faller bort.
    private var filteredGroups: [(tag: String, hosts: [Host])] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.groups }
        let needle = trimmed.lowercased()
        return model.groups.compactMap { group in
            let hosts = group.hosts.filter { host in
                host.alias.lowercased().contains(needle)
                    || host.hostName.lowercased().contains(needle)
                    || host.user.lowercased().contains(needle)
                    || host.tags.contains { $0.lowercased().contains(needle) }
            }
            return hosts.isEmpty ? nil : (group.tag, hosts)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.hosts.isEmpty {
                    ContentUnavailableView("Inga värdar än", systemImage: "server.rack",
                                           description: Text("Lägg till din första server med +."))
                } else {
                    hostList
                }
            }
            .navigationTitle("Värdar")
            .searchable(text: $searchText, prompt: "Sök värd, användare eller tagg")
            .task { _ = await model.syncNow() }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button { showSettings = true } label: { Label("Sync-inställningar", systemImage: "arrow.triangle.2.circlepath") }
                        Button { showImport = true } label: { Label("Importera ssh-config", systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Host(alias: "", hostName: "", user: "") } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { host in
                HostEditView(host: host) { model.save($0); editing = nil }
            }
            .sheet(isPresented: $showSettings) {
                SyncSettingsView(syncNow: { await model.syncNow() })
            }
            .sheet(isPresented: $showImport) {
                ImportConfigView(onImport: { model.importConfig($0) })
            }
            .cover(item: $connecting) { req in
                HostDetailView(request: req)
            }
            .alert("Lösenord", isPresented: .constant(passwordFor != nil)) {
                SecureField("Lösenord", text: $passwordInput)
                Button("Anslut") {
                    if let h = passwordFor {
                        connecting = ConnectRequest(host: h, password: passwordInput)
                    }
                    passwordFor = nil; passwordInput = ""
                }
                Button("Avbryt", role: .cancel) { passwordFor = nil; passwordInput = "" }
            }
        }
    }

    private var hostList: some View {
        List {
            ForEach(filteredGroups, id: \.tag) { group in
                Section(group.tag) {
                    ForEach(group.hosts) { host in
                        Button { start(host) } label: { HostRow(host: host) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { model.delete(host) } label: {
                                    Label("Ta bort", systemImage: "trash")
                                }
                                Button { editing = host } label: {
                                    Label("Ändra", systemImage: "pencil")
                                }.tint(.blue)
                            }
                            .swipeActions(edge: .leading) {
                                Button { model.toggleFavorite(host) } label: {
                                    Label(host.isFavorite ? "Ta bort favorit" : "Favorit",
                                          systemImage: host.isFavorite ? "star.slash" : "star")
                                }.tint(.yellow)
                            }
                    }
                }
            }
        }
    }

    private func start(_ host: Host) {
        if case .askPassword = host.auth {
            passwordFor = host
        } else {
            connecting = ConnectRequest(host: host, password: nil)
        }
    }
}

struct HostRow: View {
    let host: Host
    var body: some View {
        HStack(spacing: 12) {
            if let color = HostColorPalette.color(for: host.colorTag) {
                Circle().fill(color).frame(width: 10, height: 10)
            }
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias.isEmpty ? host.hostName : host.alias)
                    .font(.body.weight(.medium))
                Text("\(host.user)@\(host.hostName):\(host.port)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if host.isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
