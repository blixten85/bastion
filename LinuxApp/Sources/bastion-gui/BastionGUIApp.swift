import GtkBackend
import SwiftCrossUI

/// Linux-motsvarigheten till `App/` (iOS/macOS). Samma `SSHCore`, samma
/// host-databas (`~/.bastion/hosts.json`) — bara UI-lagret är bytt mot
/// SwiftCrossUI (GTK4). Beror på `GtkBackend` direkt, inte `DefaultBackend`
/// — se kommentaren i `Package.swift`. Windows-motsvarigheten (`WindowsApp/`,
/// WinUIBackend) är ett eget paket med en medvetet minimal första version —
/// se WindowsApp/Sources/bastion-gui/BastionGUIApp.swift.
@main
struct BastionGUIApp: App {
    var body: some Scene {
        WindowGroup("Bastion") {
            ContentView()
        }
        .defaultSize(width: 900, height: 560)
    }
}
