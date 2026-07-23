#if os(tvOS)
import SwiftUI
import SSHCore

/// tvOS-motsvarighet till `App/SyncSettingsView.swift`. Ingen mappsynk
/// (tvOS saknar en Filer-app) och ingen Dropbox (stödjer inte OAuth
/// device-flow, se `TVDeviceFlowOAuthManager.swift`) — bara Google Drive
/// och OneDrive, inloggade via en kod som visas på skärmen och slutförs på
/// telefonen/datorn (samma mönster som att logga in på Netflix/YouTube på
/// en Apple TV).
struct TVSyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SyncKeys.enabled) private var enabled = false
    @AppStorage(SyncKeys.transport) private var transport = "googledrive"
    // Tom vid init, fylls i via `.task` nedan — undviker att blockera
    // main actor med ett synkront Keychain-anrop under vy-initiering
    // (cubic P3, samma resonemang som `save()`).
    @State private var passphrase = ""
    // Sant först när den asynkrona Keychain-laddningen nedan slutfört sig —
    // utan denna spärr kunde "Klar"/"Synka nu" tryckas MEDAN `passphrase`
    // fortfarande var tomt-av-att-inte-hunnit-ladda, vilket `save()` då
    // tolkade som "användaren rensade fältet" och raderade en redan sparad
    // lösenfras (devin/cubic-fynd, samma granskningsrunda som async-fixet
    // ovan introducerade).
    @State private var passphraseLoaded = false
    // Sant så fort användaren rör fältet (skriver ELLER rensar) — utan
    // denna kunde en rensning som händer MEDAN laddningen fortfarande
    // pågår tolkas som "inte redigerat" och skrivas över av det laddade
    // värdet när `.task` slutför sig (cubic P2, tredje granskningsrundan).
    @State private var passphraseEdited = false
    // Sant om Keychain-läsningen faktiskt MISSLYCKADES (transient fel,
    // inte "posten finns inte") — då vet vi INTE om det finns en sparad
    // lösenfras eller ej, så save()s tomt-betyder-radera-logik måste
    // vägra köra istället för att gissa (cubic P1, tredje
    // granskningsrundan: `get()`s `nil` särskiljde inte de här fallen).
    @State private var passphraseLoadFailed = false
    @State private var status: SyncOutcome?
    // Tom vid init, fylls i via .task nedan (asynkront) — samma resonemang
    // som `passphrase` ovan, undviker synkron Keychain-IPC på main actor
    // vid vy-initiering (cubic P2, tredje granskningsrundan).
    @State private var loggedIn: [String: Bool] = [:]
    @State private var activeSession: DeviceFlowSession?
    @State private var loginError: String?
    @State private var logoutError: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var saveError: String?
    // Utan denna kan upprepade tryck på "Synka nu" köa flera samtidiga
    // fullständiga molnsynkar medan skärmen fortfarande visar förra
    // körningens status (cubic P3).
    @State private var syncInProgress = false

    let syncNow: () async -> SyncOutcome

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Synka mellan enheter", isOn: $enabled)
                } footer: {
                    Text("End-to-end-krypterat. Molntjänsten ser bara chiffertext. Mappsynk (som på iPhone/Mac) är inte tillgängligt på tvOS.")
                }
                Section {
                    Picker("Var", selection: $transport) {
                        ForEach(TVOAuthProviders.all, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    if let provider = TVOAuthProviders.all.first(where: { $0.id == transport }) {
                        accountRow(for: provider)
                    }
                } header: {
                    Text("Var")
                } footer: {
                    Text("Dropbox stödjer inte inloggning utan webbläsare (device-flow) och kan därför inte erbjudas på tvOS/watchOS — använd Google Drive eller OneDrive här, eller Dropbox på iPhone/Mac.")
                }
                Section {
                    SecureField("Lösenfras", text: Binding(
                        get: { passphrase },
                        set: { passphrase = $0; passphraseEdited = true }
                    ))
                } header: {
                    Text("Krypteringslösenfras")
                } footer: {
                    Text("Samma lösenfras på alla enheter. Tappar du den går datan inte att läsa.")
                }
                if enabled {
                    Section {
                        Button("Synka nu") {
                            // Spara lösenfrasen FÖRST — annars synkar `syncNow`
                            // mot vad som senast sparades i Keychain, inte det
                            // användaren precis skrev in (cubic P1). Kör bara
                            // synken om sparandet FAKTISKT lyckades — annars
                            // hade en misslyckad sparning tyst synkat mot den
                            // GAMLA lösenfrasen istället (cubic P1, andra
                            // granskningsrundan).
                            guard !syncInProgress else { return }
                            syncInProgress = true
                            Task {
                                defer { syncInProgress = false }
                                guard passphraseLoaded else { return }
                                guard await save() else { return }
                                status = await syncNow()
                                // Om synken upptäckte ett återkallat/utgånget
                                // token kan syncNow() ha loggat ut i tysthet
                                // (cubic P2) — läs om det så raden erbjuder
                                // omautentisering istället för att tyst
                                // fortsätta visa "Inloggad".
                                for provider in TVOAuthProviders.all {
                                    loggedIn[provider.id] = await TVDeviceFlowOAuthManager.isLoggedInAsync(provider)
                                }
                            }
                        }
                        .disabled(syncInProgress)
                        if let status {
                            Text(status.text).font(.footnote)
                                .foregroundStyle(status.isFailure ? .red : .secondary)
                        }
                    }
                    .disabled(!passphraseLoaded)
                }
            }
            .navigationTitle("Sync")
            .task {
                switch await Keychain.getResultAsync(SyncKeys.passphraseKey) {
                case .found(let value):
                    // Skriv bara in det laddade värdet om användaren inte
                    // redan rört fältet (skrivit ELLER rensat) medan
                    // laddningen pågick.
                    if !passphraseEdited { passphrase = value }
                case .notFound:
                    break
                case .failed:
                    // Vet INTE om en lösenfras faktiskt finns — save()s
                    // tomt-betyder-radera-logik måste vägra köra tills
                    // användaren själv gör något medvetet.
                    passphraseLoadFailed = true
                }
                passphraseLoaded = true
                for provider in TVOAuthProviders.all {
                    loggedIn[provider.id] = await TVDeviceFlowOAuthManager.isLoggedInAsync(provider)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klar") {
                        Task {
                            guard passphraseLoaded else { return }
                            if await save() { dismiss() }
                        }
                    }
                    .disabled(!passphraseLoaded)
                }
            }
            .sheet(item: $activeSession, onDismiss: {
                // Utan denna fortsätter en pågående device-flow-inloggning
                // att polla och kan spara ett token EFTER att användaren
                // stängt sheeten och trodde de avbrutit (cubic P2).
                loginTask?.cancel()
            }) { session in
                deviceCodeSheet(session)
            }
            .alert("Inloggning misslyckades", isPresented: Binding(
                get: { loginError != nil }, set: { if !$0 { loginError = nil } }
            )) {
                Button("OK") { loginError = nil }
            } message: {
                Text(loginError ?? "")
            }
            .alert("Utloggning misslyckades", isPresented: Binding(
                get: { logoutError != nil }, set: { if !$0 { logoutError = nil } }
            )) {
                Button("OK") { logoutError = nil }
            } message: {
                Text(logoutError ?? "")
            }
            .alert("Kunde inte spara lösenfrasen", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            // Om vyn stängs (Klar, eller att användaren navigerar bort) medan
            // en inloggning pollar: avbryt den — annars kan en redan avbruten
            // inloggning ändå slutföras och spara en token i bakgrunden,
            // eller en ny inloggning krocka med en gammal pollning som
            // fortfarande lever (cubic P2).
            .onDisappear { loginTask?.cancel() }
        }
    }

    @ViewBuilder
    private func accountRow(for provider: DeviceFlowProviderConfig) -> some View {
        if !provider.isConfigured {
            Text("\(provider.displayName) är inte konfigurerad än — se README \"Kontointegration\".")
                .font(.footnote).foregroundStyle(.secondary)
        } else if loggedIn[provider.id] == true {
            HStack {
                Text("Inloggad på \(provider.displayName)")
                Spacer()
                Button("Logga ut") {
                    // Visa bara utloggat om Keychain-raderingen faktiskt
                    // lyckades — annars kan "Logga ut" rapportera lyckat
                    // medan credentialet blir kvar (cubic P2).
                    if TVDeviceFlowOAuthManager.logout(provider) {
                        loggedIn[provider.id] = false
                    } else {
                        logoutError = "Kunde inte logga ut \(provider.displayName) — försök igen."
                    }
                }
            }
        } else {
            Button("Logga in på \(provider.displayName)") {
                startLogin(provider)
            }
        }
    }

    private func startLogin(_ provider: DeviceFlowProviderConfig) {
        // Avbryt en ev. tidigare, fortfarande pollande inloggning innan en ny
        // startas — annars kan två samtidiga pollningar krocka (cubic P2).
        loginTask?.cancel()
        loginTask = Task {
            do {
                let (session, pending) = try await TVDeviceFlowOAuthManager.begin(provider)
                activeSession = session
                try await TVDeviceFlowOAuthManager.waitForLogin(pending)
                guard !Task.isCancelled else { return }
                loggedIn[provider.id] = true
                activeSession = nil
            } catch {
                guard !Task.isCancelled else { return }
                activeSession = nil
                // `error.localizedDescription`, inte `"\(error)"` — den senare
                // skriver ut den råa enum-reflektionen (t.ex.
                // `requestFailed("...")`) och ignorerar `OAuthError`s
                // `errorDescription` (devin-fynd).
                loginError = error.localizedDescription
            }
        }
    }

    /// Stor, tydlig kod + URL — det här är vad användaren faktiskt tittar
    /// på från soffan medan de loggar in på telefonen.
    private func deviceCodeSheet(_ session: DeviceFlowSession) -> some View {
        VStack(spacing: 24) {
            Text("Gå till").font(.title3).foregroundStyle(.secondary)
            Text(session.verificationURL).font(.title.bold())
            Text("och ange koden").font(.title3).foregroundStyle(.secondary)
            Text(session.userCode).font(.system(size: 64, weight: .bold, design: .monospaced))
            ProgressView().padding(.top, 12)
        }
        .padding(60)
    }

    /// Returnerar `true` om lösenfrasen faktiskt sparades/raderades —
    /// anropare ska bara gå vidare (stänga vyn, köra en synk) vid `true`
    /// (cubic P1, andra granskningsrundan: en tyst misslyckad radering fick
    /// tidigare framstå som lyckad).
    // Async (istället för att blockera main actor rakt av) — Keychain-IPC
    // kan i värsta fall stalla UI:t om den anropas synkront här (cubic P3).
    @discardableResult
    private func save() async -> Bool {
        if passphrase.isEmpty {
            // Läsningen av den befintliga lösenfrasen misslyckades (inte
            // "det finns ingen") och användaren har inte själv rört
            // fältet — vi vet INTE om det finns en sparad lösenfras att
            // radera. Gissa inte: vägra och be användaren försöka igen
            // istället för att riskera att radera en post vi aldrig
            // faktiskt lyckades läsa (cubic P1).
            guard !passphraseLoadFailed || passphraseEdited else {
                saveError = "Kunde inte läsa den sparade lösenfrasen. Försök igen innan du sparar/synkar."
                return false
            }
            guard await Keychain.deleteAsync(SyncKeys.passphraseKey) else {
                saveError = "Lösenfrasen kunde inte raderas ur nyckelringen. Försök igen."
                return false
            }
            return true
        }
        // Ytligt fel (t.ex. Keychain otillgänglig) ska INTE stänga vyn tyst
        // med en förlorad lösenfras (cubic P1).
        guard await Keychain.setAsync(passphrase, for: SyncKeys.passphraseKey) else {
            saveError = "Lösenfrasen kunde inte sparas i nyckelringen. Försök igen."
            return false
        }
        return true
    }
}

extension DeviceFlowSession: Identifiable {
    var id: String { userCode }
}
#endif
