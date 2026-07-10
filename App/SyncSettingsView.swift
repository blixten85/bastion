#if canImport(SwiftUI)
import SwiftUI
import SSHCore
import UniformTypeIdentifiers

enum SyncKeys {
    static let enabled = "syncEnabled"
    static let folderPath = "syncFolderPath"          // visningsnamn på vald mapp
    static let folderBookmark = "syncFolderBookmark"  // security-scoped bookmark (Data)
    static let passphraseKey = "syncPassphrase"   // lagras i Keychain, inte UserDefaults
    // "folder" (standard), "dropbox", "googledrive" eller "onedrive"
    static let transport = "syncTransport"
}

struct SyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SyncKeys.enabled) private var enabled = false
    @AppStorage(SyncKeys.folderPath) private var folderPath = ""
    @AppStorage(SyncKeys.transport) private var transport = "folder"
    @State private var passphrase = Keychain.get(SyncKeys.passphraseKey) ?? ""
    @State private var status: String?
    @State private var showFolderPicker = false
    @State private var loggedIn: [String: Bool] = Dictionary(
        uniqueKeysWithValues: OAuthProviders.all.map { ($0.id, OAuthAccountManager.shared.isLoggedIn($0)) }
    )

    /// Anropas när användaren trycker "Synka nu".
    let syncNow: () async -> String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Synka mellan enheter", isOn: $enabled)
                } footer: {
                    Text("End-to-end-krypterat. Molntjänsten ser bara chiffertext.")
                }
                Section {
                    Picker("Var", selection: $transport) {
                        Text("Synkad mapp").tag("folder")
                        ForEach(OAuthProviders.all, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    if transport == "folder" {
                        Button {
                            showFolderPicker = true
                        } label: {
                            HStack {
                                Label(folderPath.isEmpty ? "Välj synkmapp…" : folderPath,
                                      systemImage: "folder")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote).foregroundStyle(.tertiary)
                            }
                        }
                        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                            if case .success(let urls) = result, let url = urls.first,
                               let name = SyncFolder.save(url) {
                                folderPath = name
                            }
                        }
                    } else if let provider = OAuthProviders.all.first(where: { $0.id == transport }) {
                        accountRow(for: provider)
                    }
                } header: {
                    Text("Transport")
                } footer: {
                    if transport == "folder" {
                        Text("Välj en mapp i iCloud Drive, Files eller en molnmapp (Dropbox/Drive/OneDrive-appen). Samma mapp på alla enheter så synkar de.")
                    }
                }
                Section {
                    SecureField("Lösenfras", text: $passphrase)
                } header: {
                    Text("Krypteringslösenfras")
                } footer: {
                    Text("Samma lösenfras på alla enheter. Tappar du den går datan inte att läsa — det är själva poängen.")
                }
                if enabled {
                    Section {
                        Button("Synka nu") {
                            Task { status = await syncNow() }
                        }
                        if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Sync")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klar") { save(); dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(for provider: OAuthProviderConfig) -> some View {
        if !provider.isConfigured {
            Text("\(provider.displayName) är inte konfigurerad än — se README \"Kontointegration\".")
                .font(.footnote).foregroundStyle(.secondary)
        } else if loggedIn[provider.id] == true {
            HStack {
                Text("Inloggad på \(provider.displayName)")
                Spacer()
                Button("Logga ut") {
                    OAuthAccountManager.shared.logout(provider)
                    loggedIn[provider.id] = false
                }
            }
        } else {
            Button("Logga in på \(provider.displayName)") {
                Task {
                    do {
                        try await OAuthAccountManager.shared.login(provider)
                        loggedIn[provider.id] = true
                    } catch {
                        status = "Inloggning misslyckades: \(error)"
                    }
                }
            }
        }
    }

    private func save() {
        if passphrase.isEmpty { Keychain.delete(SyncKeys.passphraseKey) }
        else { Keychain.set(passphrase, for: SyncKeys.passphraseKey) }
    }
}
#endif
