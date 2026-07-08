#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Flikväxlare mellan flera samtidigt anslutna värdar. `TabView` river inte
/// ner overksamma flikars vyer när man växlar (till skillnad från t.ex.
/// `NavigationStack`-push) — det är precis den egenskapen som håller
/// bakgrundssessioner faktiskt anslutna, utan någon egen livscykel-kod här.
struct MultiSessionView: View {
    @ObservedObject var manager: SessionManager
    let store: HostStore

    var body: some View {
        TabView(selection: Binding(
            get: { manager.selectedID },
            set: { manager.selectedID = $0 }
        )) {
            ForEach(manager.sessions) { session in
                HostDetailView(request: session, store: store, onClose: { manager.close(session.id) })
                    .tabItem {
                        Label(
                            session.host.alias.isEmpty ? session.host.hostName : session.host.alias,
                            systemImage: "terminal"
                        )
                    }
                    .tag(Optional(session.id))
            }
        }
    }
}
#endif
