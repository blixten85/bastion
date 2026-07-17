#if canImport(SwiftUI)
import SwiftUI
import Sentry

@main
struct BastionApp: App {
    @StateObject private var lock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SentrySDK.start { options in
            options.dsn = "https://4c2adfe9cbc58608e02fb4d52b8af3a0@o4511717224480768.ingest.de.sentry.io/4511745363673168"
            options.tracePropagationTargets = []
            options.tracesSampleRate = 0.1
            options.profilesSampleRate = 0.1
            // Session replay disabled for privacy: SSH terminal output, credentials,
            // private keys, and host details must never be captured in replays
            options.sessionReplay.onErrorSampleRate = 0.0
            options.sessionReplay.sessionSampleRate = 0.0
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                HostListView()
                if lock.isEnabled && !lock.isUnlocked {
                    AppLockView(manager: lock)
                } else if lock.isEnabled && lock.isObscured {
                    PrivacyCoverView()
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .inactive: lock.obscure()
            case .background: lock.lock()
            case .active: if lock.isUnlocked { lock.reveal() }
            @unknown default: break
            }
        }
    }
}
#endif
