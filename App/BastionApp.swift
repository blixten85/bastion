#if canImport(SwiftUI)
import SwiftUI

@main
struct BastionApp: App {
    var body: some Scene {
        WindowGroup {
            HostListView()
        }
    }
}
#endif
