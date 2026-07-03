import GtkBackend
import SwiftCrossUI

/// Linux-motsvarigheten till `App/` (iOS/macOS). Samma `SSHCore`, samma
/// host-databas (`~/.bastion/hosts.json`) — bara UI-lagret är bytt mot
/// SwiftCrossUI (GTK4). Beror på `GtkBackend` direkt, inte `DefaultBackend`
/// — se kommentaren i `Package.swift`. En Windows-version via WinUIBackend
/// är ett eget, separat steg som inte testats här.
@main
struct BastionGUIApp: App {
    var body: some Scene {
        WindowGroup("Bastion") {
            ContentView()
        }
        .defaultSize(width: 900, height: 560)
    }
}
