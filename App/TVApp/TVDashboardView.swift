#if os(tvOS)
import SwiftUI
import SSHCore

/// Läser tv-enhetens EGEN lokala `~/.bastion/hosts.json`. Synk finns nu
/// (`TVSyncSettingsView.swift`) — Google Drive/OneDrive via OAuth device-
/// flow (Dropbox saknar stöd för det, se `TVDeviceFlowOAuthManager.swift`),
/// ingen mappsynk (tvOS saknar en Filer-app). Se
/// [[project-bastion-tvos-watchos-mandate]].
struct TVDashboardView: View {
    @State private var hosts: [Host] = []
    @State private var wakingID: UUID?
    @State private var errorMessage: String?
    // Docker-vyn kräver en riktig SSH-session — `.askPassword`-värdar
    // behöver lösenordet frågat FÖRST (samma mönster som HostListViews
    // motsvarande alert i App/), övriga auth-typer löser sig själva i
    // `TVAuthResolver.resolveAuth`.
    @State private var passwordFor: Host?
    @State private var passwordInput = ""
    @State private var dockerTarget: DockerTarget?
    @State private var showSyncSettings = false
    @State private var syncStatus: String?

    private let store = HostStore()

    /// `nil` för de rutinmässiga lägena (avstängd sync, lyckad synk) —
    /// bara faktiska problem ska stjäla uppmärksamhet på en skärm utan
    /// någon "tryck för att stänga"-notis.
    private var syncFailureBanner: String? {
        guard let syncStatus, syncStatus != "Synkat.", syncStatus != "Sync är avstängd." else { return nil }
        return syncStatus
    }

    var body: some View {
        NavigationStack {
            Group {
                // Den automatiska synken vid start skrev bara till
                // `syncStatus` utan att den nånsin lästes — ett
                // misslyckande (fel lösenfras, utgången inloggning, ...)
                // var alltså osynligt för användaren (cubic P2).
                if let failure = syncFailureBanner {
                    Text(failure).font(.footnote).foregroundStyle(.red).padding(.bottom, 4)
                }
                if hosts.isEmpty {
                    ContentUnavailableView(
                        "Inga värdar",
                        systemImage: "server.rack",
                        description: Text("Slå på Sync (uppe till vänster) med Google Drive eller OneDrive, eller lägg till/synka värdar i iPhone- eller Mac-appen.")
                    )
                } else {
                    List(hosts) { host in
                        HStack {
                            Button {
                                openDocker(host)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(host.alias.isEmpty ? host.hostName : host.alias).font(.headline)
                                    Text("\(host.user)@\(host.hostName):\(host.port)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            if let mac = host.macAddress, !mac.isEmpty {
                                Button {
                                    wake(host: host, mac: mac)
                                } label: {
                                    if wakingID == host.id {
                                        ProgressView()
                                    } else {
                                        Label("Väck", systemImage: "power")
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(wakingID != nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bastion")
            .onAppear { hosts = store.all() }
            .task { syncStatus = await syncNow() }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showSyncSettings = true
                    } label: {
                        Label("Sync-inställningar", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .sheet(isPresented: $showSyncSettings) {
                TVSyncSettingsView(syncNow: syncNow)
            }
            .alert("Kunde inte väcka värden", isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } }
            ), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
            .alert("Lösenord", isPresented: .constant(passwordFor != nil)) {
                SecureField("Lösenord", text: $passwordInput)
                Button("Anslut") {
                    if let h = passwordFor {
                        dockerTarget = DockerTarget(host: h, password: passwordInput)
                    }
                    passwordFor = nil; passwordInput = ""
                }
                Button("Avbryt", role: .cancel) { passwordFor = nil; passwordInput = "" }
            }
            .navigationDestination(item: $dockerTarget) { target in
                TVDockerView(host: target.host, password: target.password)
            }
        }
    }

    /// Trimmad motsvarighet till `App/HostListView.swift`s `HostListModel.
    /// syncNow()` — bara Google Drive/OneDrive (device-flow), ingen
    /// `folder`/`dropbox`-transport (se filkommentaren ovan för varför).
    @MainActor
    private func syncNow() async -> String {
        guard UserDefaults.standard.bool(forKey: SyncKeys.enabled) else { return "Sync är avstängd." }
        guard let pass = await Keychain.getAsync(SyncKeys.passphraseKey), !pass.isEmpty else {
            return "Ingen lösenfras angiven."
        }
        let transport = UserDefaults.standard.string(forKey: SyncKeys.transport) ?? "googledrive"

        func requireLogin(_ config: DeviceFlowProviderConfig) -> String? {
            TVDeviceFlowOAuthManager.isLoggedIn(config) ? nil : "Inte inloggad på \(config.displayName)."
        }

        let provider: SyncProvider
        switch transport {
        case "googledrive":
            if let err = requireLogin(TVOAuthProviders.googleDrive) { return err }
            provider = GoogleDriveSyncProvider(passphrase: pass)
        case "onedrive":
            if let err = requireLogin(TVOAuthProviders.oneDrive) { return err }
            provider = OneDriveSyncProvider(passphrase: pass)
        default:
            return "Den valda synktransporten är inte tillgänglig på tvOS — välj Google Drive eller OneDrive i Sync-inställningar."
        }

        // `store.sync(with:)` gör blockerande, synkrona HTTP-anrop
        // (`TVOAuthTokenStore.synchronousRequest` använder en
        // `DispatchSemaphore`, se den filen). `Task.detached` räcker INTE
        // för det — det kör fortfarande på Swifts kooperativa tråd-pool,
        // och en blockerad tråd där kan svälta ut andra samtidiga tasks
        // (sentry+cubic, flera oberoende fynd om samma sak).
        //
        // `Self.syncQueue` är en SERIELL kö, inte `.global()` (som är
        // konkurrent) — annars kan den automatiska synken vid appstart och
        // ett manuellt "Synka nu"-tryck köra SAMTIDIGT och race:a om samma
        // `HostStore`/fjärrfil (push/pull-omgångar kan interfoliera och
        // temporärt skriva över varandras resultat, cubic P2, andra
        // granskningsrundan — min kommentar förra rundan påstod felaktigt
        // att detta redan var löst).
        let status = await withCheckedContinuation { continuation in
            Self.syncQueue.async {
                let result: String
                do {
                    try store.sync(with: provider)
                    result = "Synkat."
                } catch {
                    result = "Sync misslyckades: \(error.localizedDescription)"
                }
                continuation.resume(returning: result)
            }
        }

        hosts = store.all()
        return status
    }

    // `static let` — delad över ALLA instanser av vyn (bara en i praktiken,
    // men skyddar ändå mot att två separata `TVDashboardView`-instanser
    // någonsin skulle race:a om samma lokala hosts.json).
    private static let syncQueue = DispatchQueue(label: "se.denied.bastion.tv.sync")

    private func openDocker(_ host: Host) {
        if case .askPassword = host.auth {
            passwordFor = host
        } else {
            dockerTarget = DockerTarget(host: host, password: nil)
        }
    }

    @MainActor
    private func wake(host: Host, mac: String) {
        wakingID = host.id
        Task {
            do {
                try await WakeOnLan.send(mac: mac)
            } catch {
                errorMessage = error.localizedDescription
            }
            wakingID = nil
        }
    }
}

/// `navigationDestination(item:)` kräver `Identifiable` — `id` behöver
/// inte vara stabil över flera öppningar av SAMMA värd, bara unik per
/// navigeringstillfälle (en ny struct skapas varje gång `openDocker`
/// körs).
private struct DockerTarget: Identifiable, Hashable {
    let id = UUID()
    let host: Host
    let password: String?

    // Manuell konformans — `Host` är `Equatable` men inte `Hashable`, så
    // auto-syntes fungerar inte. `id` är redan unik per navigeringstillfälle
    // (se kommentaren ovan), räcker som identitet här.
    static func == (lhs: DockerTarget, rhs: DockerTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
#endif
