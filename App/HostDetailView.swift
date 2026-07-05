#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Visas när man öppnar en värd: dashboard direkt, med knapp till terminalen.
struct HostDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let request: ConnectRequest
    /// Stänger (kopplar från) den här sessionen helt — skiljer sig från
    /// "Klar" (`dismiss()`), som bara tar bort den ur sikte och lämnar den
    /// ansluten i bakgrunden. `nil` när vyn inte ingår i en flikväxlare
    /// (bör inte hända i praktiken efter multisession-omskrivningen, men
    /// låter oss ändå inte kräva en anropare för varje instansiering).
    var onClose: (() -> Void)? = nil
    @State private var showTerminal = false
    @State private var reloadToken = UUID()

    var body: some View {
        NavigationStack {
            DashboardView(request: request)
                .id(reloadToken)   // ny id => DashboardView laddar om
                .navigationTitle(request.host.alias.isEmpty ? request.host.hostName : request.host.alias)
                .navInlineTitle()
                .safeAreaInset(edge: .bottom) {
                    Button { showTerminal = true } label: {
                        Label("Öppna terminal", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Klar") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            NavigationLink { DockerView(request: request) } label: {
                                Label("Docker", systemImage: "shippingbox")
                            }
                            NavigationLink { SnippetListView(request: request) } label: {
                                Label("Snippets", systemImage: "text.badge.checkmark")
                            }
                            NavigationLink { CommandLibraryView(request: request) } label: {
                                Label("Kommandobibliotek", systemImage: "books.vertical")
                            }
                            NavigationLink { SFTPBrowserView(request: request) } label: {
                                Label("Filer (SFTP)", systemImage: "folder")
                            }
                            if let onClose {
                                Button(role: .destructive) { onClose() } label: {
                                    Label("Stäng session", systemImage: "xmark.circle")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { reloadToken = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
                .cover(isPresented: $showTerminal) {
                    SessionView(request: request)
                }
        }
    }
}
#endif
