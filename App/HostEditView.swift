#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Lägg till / ändra en värd. Enkla fält; taggar kommaseparerade.
struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Host
    @State private var portText: String
    @State private var tagsText: String
    @State private var authKind: AuthKind
    @State private var keyPath: String
    @State private var certPath: String
    @State private var keyText: String
    let onSave: (Host) -> Void

    enum AuthKind: String, CaseIterable, Identifiable {
        case agent = "Standardnyckel/agent"
        case password = "Fråga lösenord"
        case key = "Nyckelfil (sökväg)"
        case certificate = "OpenSSH-certifikat (nyckel + -cert.pub)"
        case keychainImport = "Importera nyckel"
        var id: String { rawValue }
    }

    /// Keychain-id för en importerad nyckel: stabilt per värd, oberoende av auth-läge.
    private static func keychainID(for host: Host) -> String { "host-key-\(host.id.uuidString)" }

    /// `TextField` vill ha en `Binding<String>`; `startupCommand` är
    /// `String?` (tomt fält = `nil`, inte `""` sparat i host.json).
    private var startupCommandBinding: Binding<String> {
        Binding(get: { draft.startupCommand ?? "" }, set: { draft.startupCommand = $0.isEmpty ? nil : $0 })
    }

    init(host: Host, onSave: @escaping (Host) -> Void) {
        _draft = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        _tagsText = State(initialValue: host.tags.joined(separator: ", "))
        self.onSave = onSave
        switch host.auth {
        case .agentDefault:
            _authKind = State(initialValue: .agent); _keyPath = State(initialValue: "")
            _certPath = State(initialValue: ""); _keyText = State(initialValue: "")
        case .askPassword:
            _authKind = State(initialValue: .password); _keyPath = State(initialValue: "")
            _certPath = State(initialValue: ""); _keyText = State(initialValue: "")
        case .keyFile(let p):
            _authKind = State(initialValue: .key); _keyPath = State(initialValue: p)
            _certPath = State(initialValue: ""); _keyText = State(initialValue: "")
        case .certificateFile(let keyPath, let certPath):
            _authKind = State(initialValue: .certificate); _keyPath = State(initialValue: keyPath)
            _certPath = State(initialValue: certPath); _keyText = State(initialValue: "")
        case .keychainKey(let id):
            _authKind = State(initialValue: .keychainImport); _keyPath = State(initialValue: "")
            _certPath = State(initialValue: "")
            _keyText = State(initialValue: Keychain.get(id) ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Alias (t.ex. Prod Web)", text: $draft.alias)
                    TextField("Värd (t.ex. 10.0.0.5)", text: $draft.hostName)
                        .noAutocap().autocorrectionDisabled()
                    TextField("Användare", text: $draft.user)
                        .noAutocap().autocorrectionDisabled()
                    TextField("Port", text: $portText).numberPad()
                }
                Section("Taggar") {
                    TextField("prod, homelab, …", text: $tagsText)
                        .noAutocap().autocorrectionDisabled()
                }
                Section("Favorit & färg") {
                    Toggle("Favorit", isOn: $draft.isFavorite)
                    HostColorPicker(selection: $draft.colorTag)
                }
                Section("Vid anslutning") {
                    TextField("Kör automatiskt (valfritt, t.ex. tmux attach)", text: startupCommandBinding)
                        .noAutocap().autocorrectionDisabled()
                }
                Section("Autentisering") {
                    Picker("Metod", selection: $authKind) {
                        ForEach(AuthKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if authKind == .key {
                        TextField("Sökväg till privatnyckel", text: $keyPath)
                            .noAutocap().autocorrectionDisabled()
                    }
                    if authKind == .certificate {
                        TextField("Sökväg till privatnyckel", text: $keyPath)
                            .noAutocap().autocorrectionDisabled()
                        TextField("Sökväg till certifikat (t.ex. nyckel-cert.pub)", text: $certPath)
                            .noAutocap().autocorrectionDisabled()
                    }
                    if authKind == .keychainImport {
                        TextEditor(text: $keyText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 140)
                            .noAutocap().autocorrectionDisabled()
                        if let message = keyValidationMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else if !keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Label("Giltig nyckel", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.green)
                        }
                        Text("Klistra in innehållet i din privata nyckelfil (t.ex. ~/.ssh/id_ed25519). "
                             + "Nyckeln krypteras av systemet i Keychain och lämnar aldrig enheten.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(draft.alias.isEmpty ? "Ny värd" : "Ändra värd")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Avbryt") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") { save() }.disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        let baseValid = !draft.hostName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.user.trimmingCharacters(in: .whitespaces).isEmpty
        guard baseValid else { return false }
        switch authKind {
        case .keychainImport:
            guard !keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return keyValidationMessage == nil
        case .key:
            return !keyPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .certificate:
            return !keyPath.trimmingCharacters(in: .whitespaces).isEmpty
                && !certPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .agent, .password:
            return true
        }
    }

    /// `nil` om nyckeltexten (om ifylld) tolkas som en giltig okrypterad OpenSSH-nyckel.
    private var keyValidationMessage: String? {
        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try OpenSSHPrivateKey.parse(keyText)
            return nil
        } catch SSHKeyError.encrypted {
            return "Krypterade nycklar (lösenfras) stöds inte än."
        } catch {
            return "Kunde inte tolka nyckeln: \(error)"
        }
    }

    private func save() {
        var host = draft
        host.port = Int(portText) ?? 22
        host.tags = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Rensa en tidigare importerad nyckel ur Keychain om metoden byts bort.
        if case .keychainKey(let oldID) = draft.auth, authKind != .keychainImport {
            Keychain.delete(oldID)
        }
        switch authKind {
        case .agent: host.auth = .agentDefault
        case .password: host.auth = .askPassword
        case .key: host.auth = .keyFile(keyPath)
        case .certificate: host.auth = .certificateFile(keyPath: keyPath, certPath: certPath)
        case .keychainImport:
            let id = Self.keychainID(for: host)
            Keychain.set(keyText, for: id)
            host.auth = .keychainKey(id)
        }
        if host.alias.trimmingCharacters(in: .whitespaces).isEmpty { host.alias = host.hostName }
        onSave(host)
        dismiss()
    }
}
#endif
