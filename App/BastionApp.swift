#if canImport(SwiftUI)
import SwiftUI

@main
struct BastionApp: App {
    @StateObject private var lock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                HostListView()
                if lock.isEnabled && !lock.isUnlocked {
                    AppLockView(manager: lock)
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background { lock.lock() }
        }
    }
}
#endif
