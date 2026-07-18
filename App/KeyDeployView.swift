#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Generera en ny SSH-nyckel, deploya den till fjärrsidans `authorized_keys`,
/// verifiera tyst att den faktiskt fungerar — och ENDAST om det lyckas,
/// erbjud (opt-in, aldrig automatiskt) att byta host-profilen till
/// nyckel-auth. Motsvarar `LinuxApp/Sources/bastion-gui/KeyDeployView.swift`,
/// men lagrar nyckeln i Keychain (`.keychainKey`) istället för en fil på
/// disk — App/ har, till skillnad från LinuxApp, en riktig Keychain att
/// lagra hemligheten i, och det är redan det etablerade mönstret för
/// importerade nycklar (`HostEditView.swift`, samma ID-schema återanvänt
/// här för konsekvens). Rör ALDRIG fjärrserverns egen
/// autentiseringskonfiguration — se [[feedback_password_removal_scope]].
@MainActor
final class KeyDeployModel: ObservableObject {
    @Published var generatedKey: GeneratedKeyPair?
    @Published var deployed = false
    @Published var verified = false
    @Published var statusMessage: String?
    @Published var importError: String?
    @Published var busy = false
    private let host: Host
    private let password: String?
    private let comment: String
    /// För att slå upp en ev. jump-host, se `resolveConnectionPlan`. `nil`
    /// på anropsplatser utan delad store — bara en host UTAN jump-host
    /// ansluter då direkt; en host MED jumpHostID nekas anslutning
    /// (jump-hosten går inte att lösa upp utan store), se `resolveConnectionPlan`.
    private let store: HostStore?

    init(host: Host, password: String?, store: HostStore? = nil) {
        self.host = host
        self.password = password
        self.store = store
        self.comment = "bastion-\(host.alias.isEmpty ? host.hostName : host.alias)"
    }

    /// Samma ID-schema som `HostEditView.keychainID(for:)` — en host som
    /// redan har en manuellt importerad nyckel får den ERSATT (inte en
    /// föräldralös andra Keychain-post) eftersom `Keychain.set` raderar
    /// innan den lägger till.
    private static func keychainID(for host: Host) -> String { "host-key-\(host.id.uuidString)" }

    /// Importerar en BEFINTLIG privat nyckel (klistrad OpenSSH PEM-text)
    /// istället för att generera en ny — samma efterföljande deploy+verify-
    /// flöde återanvänds rakt av, `generatedKey` sätts bara från en annan
    /// källa. Skiljer sig från HostEditViews importflöde: DEN vägen
    /// använder en redan existerande nyckel bara för AUTENTISERING (kopplar
    /// den till en host-profil), aldrig installerar den publika halvan på
    /// en fjärrserver — den här funktionen gör precis det.
    func importExisting(pem: String) {
        guard !busy else { return }
        importError = nil
        do {
            let auth = try OpenSSHPrivateKey.parse(pem)
            guard case .ed25519Seed(let seed) = auth else {
                importError = "Bara Ed25519-nycklar stöds."
                return
            }
            generatedKey = try KeyGenerator.fromExisting(seed: seed, comment: comment)
            deployed = false
            verified = false
            statusMessage = nil
        } catch SSHKeyError.encrypted {
            importError = "Lösenfras-skyddade nycklar stöds inte än."
        } catch {
            importError = "Kunde inte tolka nyckeln: \(error)"
        }
    }

    func generate() {
        // Busy-vakten hindrar att en pågående deployAndVerify() jobbar mot
        // en nyckel som hunnit bytas ut under tiden — samma CodeRabbit-fynd
        // som LinuxApp-motsvarigheten (PR #73): annars kunde ett SENT
        // lyckat verifieringssvar för den GAMLA nyckeln råka sätta
        // `verified = true` efter att `generatedKey` redan pekar på en NY,
        // aldrig deployad/verifierad nyckel.
        guard !busy else { return }
        generatedKey = KeyGenerator.generateEd25519(comment: comment)
        deployed = false
        verified = false
        statusMessage = nil
        importError = nil
    }

    func deployAndVerify() async {
        // Samma vakt som generate() — utan den kan ett andra, samtidigt
        // anrop (t.ex. dubbel-aktivering via tillgänglighetsverktyg) starta
        // en till SSH-session som kör race mot samma @Published-tillstånd
        // (CodeRabbit-fynd, #126). Knappens `.disabled(model.busy)` räcker
        // inte ensamt — den är UI-lagret, inte en garanti.
        guard !busy, let key = generatedKey else { return }
        busy = true
        deployed = false
        verified = false
        statusMessage = nil
        defer { busy = false }
        guard let plan = resolveConnectionPlan(for: host, password: password, store: store) else {
            statusMessage = "Kan inte autentisera värden (eller dess jump-host, om en är vald)."
            return
        }
        do {
            let chain = try await SSHConnectionChain.connect(
                target: host.target, targetAuth: plan.auth, jump: plan.jump)
            // Kedjan ska stängas oavsett om deployPublicKey lyckas eller
            // kastar — annars läcker en öppen SSH-anslutning vid fel.
            let deployResult: Result<Void, Error>
            do {
                try await chain.target.deployPublicKey(key.publicKeyLine, platform: host.platform)
                deployResult = .success(())
            } catch {
                deployResult = .failure(error)
            }
            await chain.close()
            try deployResult.get()
            deployed = true
        } catch {
            statusMessage = "Deploy misslyckades: \(error)"
            return
        }

        let ok = await SSHSession.verifyKeyAuthWorks(
            target: host.target, seed: key.seed, knownHosts: KnownHosts(), jump: plan.jump)
        // `generate()` kan inte köra medan `busy` är sant (se guarden ovan),
        // men kontrollen här är ändå den definitiva garantin: verifierings-
        // resultatet gäller bara om det fortfarande är SAMMA nyckel som
        // `generatedKey` pekar på.
        guard generatedKey?.publicKeyLine == key.publicKeyLine else {
            statusMessage = "Nyckeln ändrades under verifieringen. Kör deploy + verifiera igen."
            return
        }
        verified = ok
        statusMessage = ok
            ? "Nyckeln verifierad — fungerar."
            : "Verifiering misslyckades. Lösenordet är kvar, ingenting ändrat."
    }

    /// Lagrar nyckeln i Keychain och returnerar en uppdaterad `Host` med
    /// `auth = .keychainKey(id)`. Anropas bara efter att `verified` är
    /// sant — vyns checkbox styr NÄR, inte modellen (opt-in, matchar
    /// användarens uttryckliga krav).
    func saveKeyAndSwitchAuth() throws -> Host {
        guard let key = generatedKey, verified else {
            throw SSHError.channelFailed("nyckeln är inte verifierad än")
        }
        let pem = try OpenSSHPrivateKey.export(seed: key.seed, comment: comment)
        let id = Self.keychainID(for: host)
        guard Keychain.set(pem, for: id) else {
            throw SSHError.channelFailed("kunde inte spara nyckeln i Keychain")
        }
        var updated = host
        updated.auth = .keychainKey(id)
        return updated
    }
}

struct KeyDeployView: View {
    @StateObject private var model: KeyDeployModel
    @State private var switchAuthAfterVerify = false
    @State private var saveError: String?
    // "Klistra in befintlig" är ett HELT SKILT flöde från import på
    // värdredigeringssidan (HostEditView) — den använder bara en befintlig
    // nyckel för AUTENTISERING, aldrig installerar den publika halvan på en
    // fjärrserver. Den här knappen gör precis det.
    @State private var showPasteImport = false
    @State private var pastedKey = ""
    let onHostUpdated: (Host) -> Void

    init(request: ConnectRequest, store: HostStore? = nil, onHostUpdated: @escaping (Host) -> Void) {
        _model = StateObject(wrappedValue: KeyDeployModel(host: request.host, password: request.password, store: store))
        self.onHostUpdated = onHostUpdated
    }

    var body: some View {
        Form {
            Section {
                Text("Genererar en ny Ed25519-nyckel, installerar den på fjärrservern och "
                     + "verifierar att den fungerar innan något ändras lokalt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if showPasteImport {
                Section("Klistra in befintlig nyckel") {
                    TextEditor(text: $pastedKey)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .noAutocap().autocorrectionDisabled()
                    if let e = model.importError {
                        Text(e).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Avbryt") { showPasteImport = false; pastedKey = "" }
                        Spacer()
                        Button("Importera") {
                            model.importExisting(pem: pastedKey)
                            switchAuthAfterVerify = false
                            saveError = nil
                            if model.importError == nil { showPasteImport = false; pastedKey = "" }
                        }
                        .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            if let key = model.generatedKey {
                Section("Publik nyckel") {
                    Text(key.publicKeyLine)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let s = model.statusMessage {
                Section {
                    Text(s).foregroundStyle(model.verified ? .green : .red)
                }
            }
            if let e = saveError {
                Section { Text(e).foregroundStyle(.red) }
            }

            Section {
                Button(model.generatedKey == nil ? "Generera nyckel" : "Generera ny nyckel") {
                    model.generate()
                    switchAuthAfterVerify = false
                    saveError = nil
                    showPasteImport = false
                }
                .disabled(model.busy)

                if !showPasteImport {
                    Button("Klistra in befintlig nyckel istället") {
                        showPasteImport = true
                        pastedKey = ""
                    }
                    .disabled(model.busy)
                }

                if model.generatedKey != nil {
                    Button(model.busy ? "Arbetar…" : "Deploya + verifiera") {
                        Task { await model.deployAndVerify() }
                    }
                    .disabled(model.busy)
                }
            }

            if model.verified {
                Section {
                    Toggle("Byt den här värden till nyckel-auth (fråga inte längre efter lösenord)",
                           isOn: $switchAuthAfterVerify)
                    Button("Bekräfta") { confirm() }
                        .disabled(!switchAuthAfterVerify)
                }
            }
        }
        .navigationTitle("SSH-nyckel")
        .navInlineTitle()
    }

    private func confirm() {
        do {
            let updated = try model.saveKeyAndSwitchAuth()
            onHostUpdated(updated)
        } catch {
            saveError = "\(error)"
        }
    }
}
#endif
