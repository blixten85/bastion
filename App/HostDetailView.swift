#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Visas när man öppnar en värd: dashboard direkt, med knapp till terminalen.
struct HostDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let request: ConnectRequest
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
