#if canImport(SwiftUI)
import SwiftUI
import SSHCore
import UniformTypeIdentifiers

@MainActor
final class WireGuardProfileListModel: ObservableObject {
    private let store = WireGuardProfileStore()
    @Published var profiles: [WireGuardProfile] = []

    init() { reload() }
    func reload() { profiles = store.all() }
    func save(_ profile: WireGuardProfile) { store.upsert(profile); reload() }
    func delete(_ profile: WireGuardProfile) { store.delete(profile.id); reload() }
}

/// Lista över sparade WireGuard-profiler — toppnivå, inte kopplat till en
/// specifik `Host` (en profil beskriver en VPN-anslutning, inte en SSH-värd).
/// Samma v1-avgränsning som LinuxApp:s motsvarighet: profilhantering
/// (importera/visa/redigera/ta bort `.conf`-text), INTE att faktiskt
/// upprätta tunneln — se `WireGuardConfig.swift`s doc-kommentar.
struct WireGuardProfileListView: View {
    @StateObject private var model = WireGuardProfileListModel()
    @State private var editingProfile: WireGuardProfile?

    var body: some View {
        NavigationStack {
            Group {
                if model.profiles.isEmpty {
                    ContentUnavailableView("Inga profiler än", systemImage: "network.badge.shield.half.filled",
                                           description: Text("Klistra in innehållet från en .conf-fil för att spara en."))
                } else {
                    List {
                        ForEach(model.profiles) { profile in
                            Button { editingProfile = profile } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).font(.body.weight(.medium))
                                    Text(summary(profile.config)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { model.delete(profile) } label: {
                                    Label("Ta bort", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("WireGuard-profiler")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingProfile = WireGuardProfile(name: "", config: WireGuardConfig())
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editingProfile) { profile in
                WireGuardProfileEditView(
                    profile: profile,
                    onSave: { model.save($0); editingProfile = nil },
                    onCancel: { editingProfile = nil }
                )
            }
        }
    }

    private func summary(_ config: WireGuardConfig) -> String {
        let address = config.interface.address.first ?? "ingen adress"
        let peerWord = config.peers.count == 1 ? "peer" : "peers"
        return "\(address) · \(config.peers.count) \(peerWord)"
    }
}

/// Redigerar en `WireGuardProfile` som rå `.conf`-text — enklare och mer
/// direkt begripligt för en användare som redan har filen (från sin
/// VPN-leverantör/router) än ett fält-för-fält-formulär. `WireGuardConfig
/// (text:)` är förlåtande (okända rader hoppas tyst över) så ogiltig text
/// ger bara en tom/ofullständig profil, inte en krasch.
struct WireGuardProfileEditView: View {
    let profile: WireGuardProfile
    let onSave: (WireGuardProfile) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var text: String
    @State private var showFileImporter = false

    init(profile: WireGuardProfile, onSave: @escaping (WireGuardProfile) -> Void, onCancel: @escaping () -> Void) {
        self.profile = profile
        self.onSave = onSave
        self.onCancel = onCancel
        self._name = State(wrappedValue: profile.name)
        self._text = State(wrappedValue: profile.config.rendered())
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Namn", text: $name)
                        .noAutocap().autocorrectionDisabled()
                }
                Section("Välj en .conf-fil eller klistra in innehållet") {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Välj .conf-fil…", systemImage: "doc.badge.plus")
                    }
                    .fileImporter(isPresented: $showFileImporter,
                                  allowedContentTypes: FileImport.textLike) { result in
                        if let content = FileImport.readText(from: result) { text = content }
                    }
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .font(.system(.footnote, design: .monospaced))
                        .noAutocap().autocorrectionDisabled()
                }
            }
            .navigationTitle("WireGuard-profil")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") {
                        var updated = profile
                        updated.name = trimmedName
                        updated.config = WireGuardConfig(text: text)
                        onSave(updated)
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}
#endif
