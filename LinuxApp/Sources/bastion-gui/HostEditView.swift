import Foundation
import SSHCore
import SwiftCrossUI

/// Lägg till / ändra en värd. Motsvarar `App/HostEditView.swift`, men utan
/// Keychain-nyckelimport (se `AuthResolver.swift`) — bara sökväg till nyckelfil.
struct HostEditView: View {
    @State private var draft: Host
    @State private var portText: String
    @State private var tagsText: String
    @State private var authKind: AuthKind
    @State private var keyPath: String
    let onSave: (Host) -> Void
    let onCancel: () -> Void

    enum AuthKind: Equatable, CustomStringConvertible {
        case agent, password, key
        /// Bevarar en `.keychainKey`-värd oförändrad — Linux/Windows saknar
        /// Keychain och kan varken läsa eller skriva sådana nycklar (se
        /// `AuthResolver.swift`), så vi rör inte kopplingen om användaren inte
        /// aktivt väljer bort den.
        case importedElsewhere(String)

        var description: String {
            switch self {
            case .agent: return "Standardnyckel/agent"
            case .password: return "Fråga lösenord"
            case .key: return "Nyckelfil (sökväg)"
            case .importedElsewhere: return "Importerad nyckel (endast iOS/macOS)"
            }
        }
    }

    /// Valbara lägen: de tre vanliga, plus — bara om värden redan har en —
    /// det bevarade Keychain-läget.
    private var pickerOptions: [AuthKind] {
        var options: [AuthKind] = [.agent, .password, .key]
        if case .keychainKey(let id) = draft.auth { options.append(.importedElsewhere(id)) }
        return options
    }

    /// `Picker` vill ha en `Binding<AuthKind?>`; vår state är alltid satt så
    /// vi översätter bara `set` genom `nil`.
    private var authKindBinding: Binding<AuthKind?> {
        Binding(get: { authKind }, set: { if let v = $0 { authKind = v } })
    }

    init(host: Host, onSave: @escaping (Host) -> Void, onCancel: @escaping () -> Void) {
        self._draft = State(wrappedValue: host)
        self._portText = State(wrappedValue: String(host.port))
        self._tagsText = State(wrappedValue: host.tags.joined(separator: ", "))
        self.onSave = onSave
        self.onCancel = onCancel
        switch host.auth {
        case .agentDefault:
            self._authKind = State(wrappedValue: .agent)
            self._keyPath = State(wrappedValue: "")
        case .askPassword:
            self._authKind = State(wrappedValue: .password)
            self._keyPath = State(wrappedValue: "")
        case .keyFile(let p):
            self._authKind = State(wrappedValue: .key)
            self._keyPath = State(wrappedValue: p)
        case .keychainKey(let id):
            self._authKind = State(wrappedValue: .importedElsewhere(id))
            self._keyPath = State(wrappedValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.alias.isEmpty ? "Ny värd" : "Ändra värd").font(.headline)

            TextField("Alias (t.ex. Prod Web)", text: $draft.alias)
            TextField("Värd (t.ex. 10.0.0.5)", text: $draft.hostName)
            TextField("Användare", text: $draft.user)
            TextField("Port", text: $portText)
            TextField("Taggar (prod, homelab, …)", text: $tagsText)

            Toggle("Favorit", isOn: $draft.isFavorite)
            HostColorPicker(selection: $draft.colorTag)

            Text("Autentisering").font(.subheadline)
            Picker(of: pickerOptions, selection: authKindBinding)
            if authKind == .key {
                TextField("Sökväg till privatnyckel", text: $keyPath)
            }

            HStack {
                Button("Avbryt") { onCancel() }
                Spacer()
                Button("Spara") { save() }.disabled(!isValid)
            }
        }
        .padding()
    }

    private var isValid: Bool {
        !draft.hostName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        var host = draft
        host.port = Int(portText) ?? 22
        host.tags = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch authKind {
        case .agent: host.auth = .agentDefault
        case .password: host.auth = .askPassword
        case .key: host.auth = .keyFile(keyPath)
        case .importedElsewhere(let id): host.auth = .keychainKey(id)
        }
        if host.alias.trimmingCharacters(in: .whitespaces).isEmpty { host.alias = host.hostName }
        onSave(host)
    }
}
