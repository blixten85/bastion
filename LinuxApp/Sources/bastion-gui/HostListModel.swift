import SSHCore
import SwiftCrossUI

/// Delar host-databasen till vyerna och håller den observerbar.
/// Samma roll som `App/HostListView.swift`s `HostListModel`.
@MainActor
class HostListModel: ObservableObject {
    private let store = HostStore()
    @Published var hosts: [Host] = []

    init() { reload() }
    func reload() { hosts = store.all().sorted { $0.alias < $1.alias } }
    func save(_ host: Host) { store.upsert(host); reload() }
    func delete(_ host: Host) { store.delete(host.id); reload() }

    @discardableResult
    func importConfig(_ text: String) -> Int {
        let n = store.importSSHConfig(text).count
        reload()
        return n
    }
}
