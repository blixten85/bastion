#if canImport(SwiftUI)
import SwiftUI
import LocalAuthentication

enum AppLockKeys {
    static let enabled = "appLockEnabled"
}

/// Låser hela appen bakom Face ID/Touch ID/enhetslösenkod när den kommer
/// tillbaka från bakgrunden. Frivilligt (av som standard) — Keychain skyddar
/// redan hemligheterna på disk i sig, det här är ett extra UI-lager mot att
/// någon som plockar upp den olåsta telefonen rakt av ser host-listan.
@MainActor
final class AppLockManager: ObservableObject {
    @Published var isUnlocked = true

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppLockKeys.enabled)
    }

    /// Anropas när appen går till bakgrunden — nästa gång den blir aktiv
    /// krävs autentisering igen (om påslaget).
    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    @discardableResult
    func authenticate() async -> Bool {
        guard isEnabled else { isUnlocked = true; return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Ingen biometri/lösenkod konfigurerad på enheten — släpp igenom
            // hellre än att låsa ute permanent (t.ex. en simulator utan
            // Face ID/passcode konfigurerat).
            isUnlocked = true
            return true
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "Lås upp Bastion")
            isUnlocked = success
            return success
        } catch {
            isUnlocked = false
            return false
        }
    }
}

/// Visas ovanpå allt annat när appen är låst.
struct AppLockView: View {
    @ObservedObject var manager: AppLockManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Bastion är låst").font(.headline)
            Button("Lås upp") { Task { await manager.authenticate() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await manager.authenticate() }
    }
}

/// Minimal, egen inställningsyta (inte del av Sync-vyn — orelaterat syfte).
struct AppLockSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLockKeys.enabled) private var enabled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Kräv Face ID/Touch ID", isOn: $enabled)
                } footer: {
                    Text("Låser appen när den kommer tillbaka från bakgrunden. Faller tillbaka på enhetens lösenkod om biometri inte är tillgänglig.")
                }
            }
            .navigationTitle("App-lås")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klar") { dismiss() }
                }
            }
        }
    }
}
#endif
