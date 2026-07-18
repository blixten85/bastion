import Foundation
import SSHCore
import SwiftCrossUI

/// Toppnivå: värdlista i sidopanelen, dashboard/kommando i detaljvyn.
/// Motsvarar `App/HostListView.swift` + `App/HostDetailView.swift`
/// tillsammans, anpassat till `NavigationSplitView` utan iOS-sheets.
struct ContentView: View {
    @State private var model = HostListModel()
    @State private var selectedHostID: UUID?
    @State private var editingHost: Host?
    @State private var showEditor = false
    @State private var showImport = false
    @State private var showWireGuard = false
    @State private var showTailscale = false
    @State private var showS3 = false
    @State private var searchText = ""

    private var filteredHosts: [Host] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.hosts }
        let needle = trimmed.lowercased()
        return model.hosts.filter { host in
            host.alias.lowercased().contains(needle)
                || host.hostName.lowercased().contains(needle)
                || host.user.lowercased().contains(needle)
                || host.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let host = model.hosts.first(where: { $0.id == selectedHostID }) {
                HostDetailView(host: host, store: model.store, onHostUpdated: { model.save($0) })
            } else {
                ContentUnavailableView {
                    Text("Ingen värd vald")
                } description: {
                    Text("Välj en värd i listan, eller lägg till en ny.")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let editingHost {
                HostEditView(
                    host: editingHost,
                    allHosts: model.hosts,
                    onSave: { host in
                        model.save(host)
                        selectedHostID = host.id
                        showEditor = false
                    },
                    onCancel: { showEditor = false }
                )
            }
        }
        .sheet(isPresented: $showImport) {
            ImportConfigView(
                onImport: { text in
                    model.importConfig(text)
                    showImport = false
                },
                onCancel: { showImport = false }
            )
        }
        .sheet(isPresented: $showWireGuard) {
            WireGuardProfileListView()
        }
        .sheet(isPresented: $showTailscale) {
            TailscaleDiscoveryView(
                hosts: model.hosts,
                onAddHost: { alias, hostName in
                    editingHost = Host(alias: alias, hostName: hostName, user: "")
                    showTailscale = false
                    showEditor = true
                },
                onCancel: { showTailscale = false },
                store: model.store
            )
        }
        .sheet(isPresented: $showS3) {
            S3ConnectionListView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Ny värd") {
                    editingHost = Host(alias: "", hostName: "", user: "")
                    showEditor = true
                }
                Button("Importera") { showImport = true }
                Button("WireGuard") { showWireGuard = true }
                Button("Tailscale") { showTailscale = true }
                Button("S3") { showS3 = true }
                Spacer()
            }

            TextField("Sök…", text: $searchText)

            List(filteredHosts, selection: $selectedHostID) { host in
                HStack {
                    if let color = HostColorPalette.color(for: host.colorTag) {
                        Circle().fill(color).frame(width: 10, height: 10)
                    }
                    VStack(alignment: .leading) {
                        Text(host.alias.isEmpty ? host.hostName : host.alias)
                        Text(host.tags.isEmpty ? "\(host.user)@\(host.hostName)" : host.tags.joined(separator: ", "))
                            .foregroundColor(.gray)
                    }
                    if host.isFavorite {
                        Text("★").foregroundColor(.yellow)
                    }
                }
            }

            if let selected = model.hosts.first(where: { $0.id == selectedHostID }) {
                HStack {
                    Button("Ändra") {
                        editingHost = selected
                        showEditor = true
                    }
                    Button(selected.isFavorite ? "★ Favorit" : "☆ Favorit") {
                        model.toggleFavorite(selected)
                    }
                    Button("Ta bort") {
                        model.delete(selected)
                        selectedHostID = nil
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 240)
    }
}
