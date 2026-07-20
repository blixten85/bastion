#if os(tvOS)
import SwiftUI

/// Separat, minimal tvOS-app — INTE samma target som iOS/macOS-appen
/// (`App/BastionApp.swift`). Apple TV Siri Remote saknar ett praktiskt
/// tangentbord för interaktiv SSH-terminal, så scope här är avsiktligt
/// begränsat till en "dashboard": se värdlistan, väck en sovande maskin
/// via Wake-on-LAN. Ingen terminal, ingen SFTP, ingen värdredigering —
/// de hanteras på telefon/dator; tv:n är en glansfri statuspanel.
@main
struct TVBastionApp: App {
    var body: some Scene {
        WindowGroup {
            TVDashboardView()
        }
    }
}
#endif
