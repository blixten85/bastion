#if canImport(SwiftUI)
import SwiftUI
import SSHCore

@MainActor
final class SnippetListModel: ObservableObject {
    private let store = SnippetStore()
    @Published var snippets: [Snippet] = []

    init() { reload() }
    func reload() { snippets = store.all() }
    func save(_ snippet: Snippet) { store.upsert(snippet); reload() }
    func delete(_ snippet: Snippet) { store.delete(snippet.id); reload() }
}

/// Lista över sparade snippets — lägg till/ändra/ta bort, och kör en mot en
/// vald värd (fyll i variabler, skicka som startkommando till en ny terminal).
struct SnippetListView: View {
    let request: ConnectRequest
    @StateObject private var model = SnippetListModel()
    @State private var editing: Snippet?
    @State private var running: Snippet?
    @State private var runningRequest: ConnectRequest?

    var body: some View {
        Group {
            if model.snippets.isEmpty {
                ContentUnavailableView("Inga snippets än", systemImage: "text.badge.plus",
                                       description: Text("Lägg till ett kommando med + — t.ex. \"docker compose restart {{service}}\"."))
            } else {
                List {
                    ForEach(model.snippets) { snippet in
                        Button { running = snippet } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.name).font(.body.weight(.medium))
                                Text(snippet.template).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.delete(snippet) } label: {
                                Label("Ta bort", systemImage: "trash")
                            }
                            Button { editing = snippet } label: {
                                Label("Ändra", systemImage: "pencil")
                            }.tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Snippets")
        .navInlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Snippet(name: "", template: "") } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditView(snippet: snippet, onSave: { model.save($0); editing = nil }, onCancel: { editing = nil })
        }
        .sheet(item: $running) { snippet in
            SnippetRunView(snippet: snippet, onRun: { command in
                running = nil
                runningRequest = request.running(command)
            }, onCancel: { running = nil })
        }
        .cover(item: $runningRequest) { req in
            SessionView(request: req)
        }
    }
}

/// Fyll i variabler (om snippet har några) innan den skickas.
private struct SnippetRunView: View {
    let snippet: Snippet
    let onRun: (String) -> Void
    let onCancel: () -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                if snippet.variableNames.isEmpty {
                    Section {
                        Text(snippet.template).font(.system(.body, design: .monospaced))
                    }
                } else {
                    Section("Variabler") {
                        ForEach(snippet.variableNames, id: \.self) { name in
                            TextField(name, text: Binding(
                                get: { values[name] ?? "" },
                                set: { values[name] = $0 }
                            ))
                            .noAutocap().autocorrectionDisabled()
                        }
                    }
                    Section("Förhandsvisning") {
                        Text(snippet.rendered(with: values)).font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(snippet.name)
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kör") { onRun(snippet.rendered(with: values)) }
                }
            }
        }
    }
}
#endif
