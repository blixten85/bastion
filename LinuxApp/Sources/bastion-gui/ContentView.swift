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
    @State private var searchText = ""

    private var filteredHosts: [Host] {
        guard !searchText.isEmpty else { return model.hosts }
        let needle = searchText.lowercased()
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
                HostDetailView(host: host)
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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Ny värd") {
                    editingHost = Host(alias: "", hostName: "", user: "")
                    showEditor = true
                }
                Button("Importera") { showImport = true }
                Spacer()
            }

            TextField("Sök…", text: $searchText)

            List(filteredHosts, selection: $selectedHostID) { host in
                VStack(alignment: .leading) {
                    Text(host.alias.isEmpty ? host.hostName : host.alias)
                    Text(host.tags.isEmpty ? "\(host.user)@\(host.hostName)" : host.tags.joined(separator: ", "))
                        .foregroundColor(.gray)
                }
            }

            if let selected = model.hosts.first(where: { $0.id == selectedHostID }) {
                HStack {
                    Button("Ändra") {
                        editingHost = selected
                        showEditor = true
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
