#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Håller alla samtidigt öppna sessioner (flera värdar anslutna parallellt,
/// växlingsbara via flikar i `MultiSessionView`) — Fas B i ROADMAP.md
/// ("flera samtidiga sessioner"). En session stannar ansluten i bakgrunden
/// tills den stängs explicit, inte bara döljs (SwiftUIs `TabView` river inte
/// ner overksamma flikars vyer, till skillnad från `NavigationStack`).
@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [ConnectRequest] = []
    @Published var selectedID: UUID?

    func open(_ request: ConnectRequest) {
        sessions.append(request)
        selectedID = request.id
    }

    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        guard selectedID == id else { return }
        selectedID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
    }
}
#endif
