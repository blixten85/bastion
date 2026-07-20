#if canImport(SwiftUI)
import SwiftUI
import SSHCore
import UniformTypeIdentifiers

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
    @State private var showKeyImporter = false
    @State private var bitwardenItemIDText: String
    /// Övriga sparade värdar, för jump-host-väljaren nedan. Utesluter alltid
    /// `draft.id` själv (kan inte vara sin egen jump-host) — djupare
    /// cykeldetektering (A→B→A) görs inte här, bara den mest uppenbara.
    let allHosts: [Host]
    let onSave: (Host) -> Void

    enum AuthKind: String, CaseIterable, Identifiable {
        case agent = "Standardnyckel/agent"
        case password = "Fråga lösenord"
        case key = "Nyckelfil (sökväg)"
        case certificate = "OpenSSH-certifikat (nyckel + -cert.pub)"
        case bitwarden = "Bitwarden (bw CLI, endast macOS)"
        case keychainImport = "Importera nyckel"
        var id: String { rawValue }
    }

    /// Keychain-id för en importerad nyckel: stabilt per värd, oberoende av auth-läge.
    private static func keychainID(for host: Host) -> String { "host-key-\(host.id.uuidString)" }

    /// Auth-lägen som faktiskt går att välja på DEN HÄR plattformen. Bitwarden
    /// filtreras bort på iOS (se Picker-kommentaren i `body`) men om värden
    /// REDAN har det läget (synkad från macOS) hålls det kvar i listan så att
    /// Pickern kan visa det som valt, i stället för att tyst nollställa det.
    private var availableAuthKinds: [AuthKind] {
        #if os(iOS)
        var kinds = AuthKind.allCases.filter { $0 != .bitwarden }
        if authKind == .bitwarden { kinds.append(.bitwarden) }
        return kinds
        #else
        return AuthKind.allCases
        #endif
    }

    /// Kandidater för jump host-väljaren: utesluter (1) `draft` själv, (2)
    /// `.askPassword`-värdar (går inte att autentisera automatiskt genom en
    /// jump-kedja — se `SessionView.plan`, som medvetet FAILAR anslutningen
    /// snarare än att tyst hoppa över en jump-host som inte kan autentiseras),
    /// och (3) värdar som SJÄLVA har en jump-host satt —
    /// `SSHConnectionChain`/`SessionView` stöder bara ETT hopp, så att välja
    /// en sådan kandidat skulle tyst hoppa över DESS jump-host och ansluta
    /// direkt till kandidaten istället (en kedja A→B→C skulle bara bli A→B,
    /// felaktigt utan varning). Detta gör cykler (A→B→A) strukturellt
    /// omöjliga också — en kandidat utan egen jump-host kan per definition
    /// inte peka tillbaka på något.
    private var jumpCandidates: [Host] {
        allHosts.filter { candidate in
            guard candidate.id != draft.id else { return false }
            if case .askPassword = candidate.auth { return false }
            return candidate.jumpHostID == nil
        }
    }

    /// `TextField` vill ha en `Binding<String>`; `startupCommand` är
    /// `String?` (tomt fält = `nil`, inte `""` sparat i host.json).
    private var startupCommandBinding: Binding<String> {
        Binding(get: { draft.startupCommand ?? "" }, set: { draft.startupCommand = $0.isEmpty ? nil : $0 })
    }

    /// Samma tom-sträng-till-nil-mönster som `startupCommandBinding` —
    /// `macAddress` är `String?`, tomt fält ska spara `nil`, inte `""`.
    private var macAddressBinding: Binding<String> {
        Binding(get: { draft.macAddress ?? "" }, set: { draft.macAddress = $0.isEmpty ? nil : $0 })
    }

    init(host: Host, allHosts: [Host] = [], onSave: @escaping (Host) -> Void) {
        _draft = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        _tagsText = State(initialValue: host.tags.joined(separator: ", "))
        self.allHosts = allHosts
        self.onSave = onSave
        if case .bitwardenItem(let itemID) = host.auth {
            _bitwardenItemIDText = State(initialValue: itemID)
        } else {
            _bitwardenItemIDText = State(initialValue: "")
        }
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
        case .bitwardenItem:
            _authKind = State(initialValue: .bitwarden); _keyPath = State(initialValue: "")
            _certPath = State(initialValue: ""); _keyText = State(initialValue: "")
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
                // Autentiseringen ligger näst överst — det är det man MÅSTE välja
                // rätt för att ens kunna ansluta; tidigare låg den sist och
                // användare hittade aldrig lösenordsvalet (TestFlight-feedback).
                Section("Autentisering") {
                    Picker("Metod", selection: $authKind) {
                        // Bitwarden filtreras bort på iOS — `Foundation.Process`
                        // finns inte där (samma sandbox-begränsning som
                        // `BitwardenClient`), så anslutning skulle deterministiskt
                        // misslyckas för varje värd som väljer det läget (cubic-fynd).
                        // Redan sparade `.bitwardenItem`-värdar (synkade från macOS)
                        // förblir dock läsbara/oförändrade — bara VALET döljs.
                        ForEach(availableAuthKinds) { Text($0.rawValue).tag($0) }
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
                    if authKind == .bitwarden {
                        TextField("Bitwarden item-id eller namn", text: $bitwardenItemIDText)
                            .noAutocap().autocorrectionDisabled()
                        Text("Kräver en giltig BW_SESSION i Bastion-processens EGEN miljö — att låsa "
                             + "upp valvet i en separat Terminal överför inte sessionen till appen. "
                             + "Fungerar bara på macOS — iOS saknar stöd för lokala processer.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if authKind == .keychainImport {
                        Button {
                            showKeyImporter = true
                        } label: {
                            Label("Välj nyckelfil…", systemImage: "doc.badge.plus")
                        }
                        .fileImporter(isPresented: $showKeyImporter,
                                      allowedContentTypes: FileImport.textLike,
                                      allowsMultipleSelection: false) { result in
                            if let content = FileImport.readText(from: result) { keyText = content }
                        }
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
                        Text("Välj din privata nyckelfil (t.ex. id_ed25519) eller klistra in den. "
                             + "Nyckeln krypteras av systemet i Keychain och lämnar aldrig enheten.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section("Jump host") {
                    Picker("Anslut via", selection: $draft.jumpHostID) {
                        Text("Ingen (direkt anslutning)").tag(UUID?.none)
                        ForEach(jumpCandidates) { h in
                            Text(h.alias.isEmpty ? h.hostName : h.alias).tag(Optional(h.id))
                        }
                    }
                    if let jumpID = draft.jumpHostID,
                       let jumpHost = allHosts.first(where: { $0.id == jumpID }) {
                        Text("Ansluter genom \(jumpHost.alias.isEmpty ? jumpHost.hostName : jumpHost.alias) (ssh -J) innan den här värden nås.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Bara värdar med nyckel-/agent-/certifikatautentisering visas — "
                         + "\"Fråga lösenord\"-värdar kan inte användas som jump host (ingen "
                         + "interaktiv prompt finns för det hoppet).")
                        .font(.caption2).foregroundStyle(.secondary)
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
                Section("Wake-on-LAN") {
                    TextField("MAC-adress (valfritt, t.ex. AA:BB:CC:DD:EE:FF)", text: macAddressBinding)
                        .noAutocap().autocorrectionDisabled()
                    if let message = macValidationMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Skickar ett magic packet på det lokala nätverket för att väcka en "
                         + "avstängd/vilande maskin innan anslutning. Kräver att enheten stöder "
                         + "WoL och är inställd att lyssna efter det (BIOS/nätverkskort).")
                        .font(.caption2).foregroundStyle(.secondary)
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
            && macValidationMessage == nil
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
        case .bitwarden:
            return !bitwardenItemIDText.trimmingCharacters(in: .whitespaces).isEmpty
        case .agent, .password:
            return true
        }
        // (macValidationMessage kollas separat nedan i den kombinerade `isValid`.)
    }

    /// `nil` om MAC-fältet (om ifyllt, trimmat) går att tolka — annars sparas
    /// en trasig adress tyst och Wake-knappen skulle deterministiskt misslyckas
    /// senare (cubic-fynd, PR #173).
    private var macValidationMessage: String? {
        let trimmed = (draft.macAddress ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try WakeOnLan.parseMAC(trimmed)
            return nil
        } catch {
            return "Ogiltig MAC-adress."
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
        if let mac = host.macAddress {
            let trimmed = mac.trimmingCharacters(in: .whitespaces)
            host.macAddress = trimmed.isEmpty ? nil : trimmed
        }
        // Rensa en tidigare importerad nyckel ur Keychain om metoden byts bort.
        if case .keychainKey(let oldID) = draft.auth, authKind != .keychainImport {
            Keychain.delete(oldID)
        }
        switch authKind {
        case .agent: host.auth = .agentDefault
        case .password: host.auth = .askPassword
        case .key: host.auth = .keyFile(keyPath)
        case .certificate: host.auth = .certificateFile(keyPath: keyPath, certPath: certPath)
        case .bitwarden:
            host.auth = .bitwardenItem(bitwardenItemIDText.trimmingCharacters(in: .whitespaces))
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
