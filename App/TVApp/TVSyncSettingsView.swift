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
    @State private var passphrase = Keychain.get(SyncKeys.passphraseKey) ?? ""
    @State private var status: String?
    @State private var loggedIn: [String: Bool] = Dictionary(
        uniqueKeysWithValues: TVOAuthProviders.all.map { ($0.id, TVDeviceFlowOAuthManager.isLoggedIn($0)) }
    )
    @State private var activeSession: DeviceFlowSession?
    @State private var loginError: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var saveError: String?

    let syncNow: () async -> String

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
                    SecureField("Lösenfras", text: $passphrase)
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
                            // användaren precis skrev in (cubic P1).
                            save()
                            Task { status = await syncNow() }
                        }
                        if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Sync")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klar") {
                        save()
                        if saveError == nil { dismiss() }
                    }
                }
            }
            .sheet(item: $activeSession) { session in
                deviceCodeSheet(session)
            }
            .alert("Inloggning misslyckades", isPresented: Binding(
                get: { loginError != nil }, set: { if !$0 { loginError = nil } }
            )) {
                Button("OK") { loginError = nil }
            } message: {
                Text(loginError ?? "")
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
                    TVDeviceFlowOAuthManager.logout(provider)
                    loggedIn[provider.id] = false
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
                loginError = "\(error)"
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

    private func save() {
        if passphrase.isEmpty {
            Keychain.delete(SyncKeys.passphraseKey)
            return
        }
        // Ytligt fel (t.ex. Keychain otillgänglig) ska INTE stänga vyn tyst
        // med en förlorad lösenfras — `Keychain.set` raderar den gamla
        // posten innan den skriver den nya, så ett misslyckat `SecItemAdd`
        // kan annars radera en tidigare fungerande lösenfras utan varning
        // (cubic P1).
        guard Keychain.set(passphrase, for: SyncKeys.passphraseKey) else {
            saveError = "Lösenfrasen kunde inte sparas i nyckelringen. Försök igen."
            return
        }
    }
}

extension DeviceFlowSession: Identifiable {
    var id: String { userCode }
}
#endif
