#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Lägg till / ändra ett snippet. Visar upptäckta variabler live medan man skriver.
struct SnippetEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Snippet
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    init(snippet: Snippet, onSave: @escaping (Snippet) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: snippet)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Snippet") {
                    TextField("Namn (t.ex. Starta om Plex)", text: $draft.name)
                    TextField("Kommando — {{variabel}} för ifyllbara delar", text: $draft.template, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .noAutocap().autocorrectionDisabled()
                        .lineLimit(3...6)
                }
                if !draft.variableNames.isEmpty {
                    Section("Upptäckta variabler") {
                        ForEach(draft.variableNames, id: \.self) { name in
                            Text(name).font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle(draft.name.isEmpty ? "Nytt snippet" : "Ändra snippet")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") { onSave(draft) }
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || draft.template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif
