#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import Sentry
#endif

@main
struct BastionApp: App {
    @StateObject private var lock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(iOS)
        SentrySDK.start { options in
            options.dsn = "https://4c2adfe9cbc58608e02fb4d52b8af3a0@o4511717224480768.ingest.de.sentry.io/4511745363673168"
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif
            options.tracePropagationTargets = []
            options.tracesSampleRate = 0.1
            // .manual (inte .trace) - med .trace gates appstart-profilering
            // av tracesSampleRate (0.1 ovan) oavsett sessionSampleRate, så
            // ~90% av starterna hade tappats tyst (verifierat mot SDK-
            // källkodens dokkommentar i SentryProfileOptions.swift). .manual
            // låter sessionSampleRate=1.0 gälla för sig själv - profilerna
            // avslutas explicit i body nedan när rotvyn först renderats.
            options.configureProfiling = {
                $0.lifecycle = .manual
                $0.sessionSampleRate = 1.0
                $0.profileAppStarts = true
            }
            // Session replay disabled for privacy: SSH terminal output, credentials,
            // private keys, and host details must never be captured in replays
            options.sessionReplay.onErrorSampleRate = 0.0
            options.sessionReplay.sessionSampleRate = 0.0
            options.enableLogs = true
        }
        #endif
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
            .onAppear {
                #if os(iOS)
                // Markerar slutet på det som profileAppStarts mäter - rotvyn
                // har renderats. Manuell lifecycle (se init()) kräver detta
                // explicita anrop; utan det fortsätter profileringen tills
                // SDK:t timear ut den själv.
                SentrySDK.stopProfiler()
                #endif
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
