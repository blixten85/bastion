import SSHCore
import SwiftCrossUI
import WinUIBackend

/// Windows-motsvarigheten till `LinuxApp/` — samma SSHCore, samma
/// host-databas, men SwiftCrossUIs `WinUIBackend` istället för `GtkBackend`.
/// Medvetet minimal första version: bevisar att pipelinen (Package.swift +
/// CI på windows-latest-runnern) faktiskt kompilerar innan de riktiga
/// vyerna i `LinuxApp/Sources/bastion-gui/` porteras hit. Ingen lokal
/// Windows-maskin att testköra mot ännu, så varje steg görs litet och
/// verifieras via CI istället för lokalt (som för `App/`).
@main
struct BastionGUIApp: App {
    var body: some Scene {
        WindowGroup("Bastion") {
            ContentView()
        }
        .defaultSize(width: 900, height: 560)
    }
}

struct ContentView: View {
    private var hostCount: Int {
        HostStore().all().count
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Bastion för Windows").font(.title2)
            Text("\(hostCount) sparade värdar").foregroundColor(.gray)
            Text("Fullständigt UI porteras hit i ett senare steg.").foregroundColor(.gray)
        }
        .padding()
    }
}
