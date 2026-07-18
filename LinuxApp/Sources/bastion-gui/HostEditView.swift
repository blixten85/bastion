import Foundation
import SSHCore
import SwiftCrossUI

/// Lägg till / ändra en värd. Motsvarar `App/HostEditView.swift`, men utan
/// Keychain-nyckelimport (se `AuthResolver.swift`) — bara sökväg till nyckelfil.
struct HostEditView: View {
    @State private var draft: Host
    @State private var portText: String
    @State private var tagsText: String
    @State private var startupCommandText: String
    @State private var authKind: AuthKind
    @State private var keyPath: String
    @State private var certPath: String
    /// Övriga sparade värdar, för jump-host-väljaren nedan. Utesluter alltid
    /// `draft.id` själv (kan inte vara sin egen jump-host) — djupare
    /// cykeldetektering (A→B→A) görs inte här, bara den mest uppenbara.
    let allHosts: [Host]
    let onSave: (Host) -> Void
    let onCancel: () -> Void

    /// Picker-alternativ för jump-host-väljaren: "Ingen" plus varje giltig
    /// kandidat. Ett eget värdetyp istället för `Host?` direkt, eftersom
    /// SwiftCrossUIs `Picker` kräver `Equatable` och en textbeskrivning via
    /// `CustomStringConvertible`/interpolation.
    private enum JumpChoice: Equatable, CustomStringConvertible {
        case none
        case host(UUID, String)

        static func == (lhs: JumpChoice, rhs: JumpChoice) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case (.host(let a, _), .host(let b, _)): return a == b
            default: return false
            }
        }

        var description: String {
            switch self {
            case .none: return "Ingen"
            case .host(_, let name): return name
            }
        }
    }

    /// Kandidater för jump host-väljaren: utesluter (1) `draft` själv, (2)
    /// `.askPassword`-värdar (går inte att autentisera automatiskt genom en
    /// jump-kedja), och (3) värdar som SJÄLVA har en jump-host satt —
    /// `SSHConnectionChain` stöder bara ETT hopp, så att välja en sådan
    /// kandidat skulle tyst hoppa över DESS jump-host och ansluta direkt
    /// till kandidaten istället (en kedja A→B→C skulle bara bli A→B,
    /// felaktigt utan varning). Detta gör cykler (A→B→A) strukturellt
    /// omöjliga också — en kandidat utan egen jump-host kan per definition
    /// inte peka tillbaka på något. Samma resonemang som App/HostEditView.swift.
    private var jumpCandidates: [Host] {
        allHosts.filter { candidate in
            guard candidate.id != draft.id else { return false }
            if case .askPassword = candidate.auth { return false }
            return candidate.jumpHostID == nil
        }
    }

    private var jumpChoiceOptions: [JumpChoice] {
        [.none] + jumpCandidates.map { .host($0.id, $0.alias.isEmpty ? $0.hostName : $0.alias) }
    }

    private var jumpChoiceBinding: Binding<JumpChoice?> {
        Binding(
            get: {
                guard let id = draft.jumpHostID,
                      let host = jumpCandidates.first(where: { $0.id == id })
                else { return .none }
                return .host(host.id, host.alias.isEmpty ? host.hostName : host.alias)
            },
            set: { choice in
                // `choice` är `JumpChoice?` — och `JumpChoice` har SJÄLV ett
                // `.none`-fall, så ett osyftat `case .none` här skulle bara
                // matcha Optional.none (widgeten utan val), inte vårt
                // explicita "Ingen"-val (`.some(.host)` är det enda fallet
                // som ska sätta ett jumpHostID).
                switch choice {
                case .some(.host(let id, _)): draft.jumpHostID = id
                default: draft.jumpHostID = nil
                }
            }
        )
    }

    enum AuthKind: Equatable, CustomStringConvertible {
        case agent, password, key, certificate
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
            case .certificate: return "OpenSSH-certifikat (nyckel + -cert.pub)"
            case .importedElsewhere: return "Importerad nyckel (endast iOS/macOS)"
            }
        }
    }

    /// Valbara lägen: de fyra vanliga, plus — bara om värden redan har en —
    /// det bevarade Keychain-läget.
    private var pickerOptions: [AuthKind] {
        var options: [AuthKind] = [.agent, .password, .key, .certificate]
        if case .keychainKey(let id) = draft.auth { options.append(.importedElsewhere(id)) }
        return options
    }

    /// `Picker` vill ha en `Binding<AuthKind?>`; vår state är alltid satt så
    /// vi översätter bara `set` genom `nil`.
    private var authKindBinding: Binding<AuthKind?> {
        Binding(get: { authKind }, set: { if let v = $0 { authKind = v } })
    }

    private var platformBinding: Binding<RemotePlatform?> {
        Binding(get: { draft.platform }, set: { if let v = $0 { draft.platform = v } })
    }

    init(host: Host, allHosts: [Host] = [], onSave: @escaping (Host) -> Void, onCancel: @escaping () -> Void) {
        self._draft = State(wrappedValue: host)
        self._portText = State(wrappedValue: String(host.port))
        self._tagsText = State(wrappedValue: host.tags.joined(separator: ", "))
        self._startupCommandText = State(wrappedValue: host.startupCommand ?? "")
        self.allHosts = allHosts
        self.onSave = onSave
        self.onCancel = onCancel
        switch host.auth {
        case .agentDefault:
            self._authKind = State(wrappedValue: .agent)
            self._keyPath = State(wrappedValue: "")
            self._certPath = State(wrappedValue: "")
        case .askPassword:
            self._authKind = State(wrappedValue: .password)
            self._keyPath = State(wrappedValue: "")
            self._certPath = State(wrappedValue: "")
        case .keyFile(let p):
            self._authKind = State(wrappedValue: .key)
            self._keyPath = State(wrappedValue: p)
            self._certPath = State(wrappedValue: "")
        case .certificateFile(let keyPath, let certPath):
            self._authKind = State(wrappedValue: .certificate)
            self._keyPath = State(wrappedValue: keyPath)
            self._certPath = State(wrappedValue: certPath)
        case .keychainKey(let id):
            self._authKind = State(wrappedValue: .importedElsewhere(id))
            self._keyPath = State(wrappedValue: "")
            self._certPath = State(wrappedValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.alias.isEmpty ? "Ny värd" : "Ändra värd").font(.headline)

            // ScrollView runt fälten (inte hela vyn) — antalet sektioner har
            // vuxit (jump host läggs till här) förbi vad en fast höjd alltid
            // rymmer, och Spara/Avbryt ska aldrig kunna hamna utanför
            // skärmen (samma mönster som Dashboard/Docker/PortForward-vyerna).
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
                    if authKind == .certificate {
                        TextField("Sökväg till privatnyckel", text: $keyPath)
                        TextField("Sökväg till certifikat (t.ex. nyckel-cert.pub)", text: $certPath)
                    }

                    Text("Fjärrsystem").font(.subheadline)
                    Picker(of: RemotePlatform.allCases, selection: platformBinding)

                    TextField("Kör automatiskt vid anslutning (valfritt, t.ex. tmux attach)", text: $startupCommandText)

                    Text("Jump host").font(.subheadline)
                    Picker(of: jumpChoiceOptions, selection: jumpChoiceBinding)
                    if let jumpID = draft.jumpHostID, let jumpHost = allHosts.first(where: { $0.id == jumpID }) {
                        Text("Ansluter genom \(jumpHost.alias.isEmpty ? jumpHost.hostName : jumpHost.alias) (ssh -J) innan den här värden nås.")
                            .foregroundColor(.gray)
                    }
                }
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
        guard !draft.hostName.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.user.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        switch authKind {
        case .key:
            return !keyPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .certificate:
            return !keyPath.trimmingCharacters(in: .whitespaces).isEmpty
                && !certPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .agent, .password, .importedElsewhere:
            return true
        }
    }

    private func save() {
        var host = draft
        host.port = Int(portText) ?? 22
        host.tags = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let trimmedStartup = startupCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        host.startupCommand = trimmedStartup.isEmpty ? nil : trimmedStartup
        switch authKind {
        case .agent: host.auth = .agentDefault
        case .password: host.auth = .askPassword
        case .key: host.auth = .keyFile(keyPath)
        case .certificate: host.auth = .certificateFile(keyPath: keyPath, certPath: certPath)
        case .importedElsewhere(let id): host.auth = .keychainKey(id)
        }
        if host.alias.trimmingCharacters(in: .whitespaces).isEmpty { host.alias = host.hostName }
        onSave(host)
    }
}
