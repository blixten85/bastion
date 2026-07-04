import Foundation
import SSHCore
import SwiftCrossUI

/// Bläddringsbart referensbibliotek — motsvarar `App/CommandLibraryView.swift`.
/// Ren, statisk data (`CommandLibrary.all`), ingen egen lagring.
struct CommandLibraryView: View {
    let host: Host
    let password: String?
    @State private var selectedID: String?
    @State private var runCommand: String?
    @State private var variableValues: [String: String] = [:]

    private var selectedEntry: CommandLibraryEntry? {
        CommandLibrary.all.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kommandobibliotek").font(.title2)

            List(CommandLibrary.all, id: \.id, selection: $selectedID) { entry in
                VStack(alignment: .leading) {
                    Text("\(entry.category.rawValue): \(entry.summary)")
                    Text(entry.command).foregroundColor(.gray)
                }
            }

            if let entry = selectedEntry {
                runForm(for: entry)
            }
        }
        .padding()
        .sheet(isPresented: Binding(get: { runCommand != nil }, set: { if !$0 { runCommand = nil } })) {
            TerminalSessionView(host: host, password: password, initialCommand: runCommand)
        }
    }

    private func runForm(for entry: CommandLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Kör: \(entry.summary)").font(.headline)
            if let example = entry.example {
                Text("Exempel: \(example)").foregroundColor(.gray)
            }
            let snippet = entry.asSnippet
            if snippet.variableNames.isEmpty {
                Text(snippet.template).foregroundColor(.gray)
            } else {
                ForEach(snippet.variableNames, id: \.self) { name in
                    TextField(name, text: variableBinding(name))
                }
            }
            HStack {
                Button("Avbryt") { selectedID = nil }
                Button("Kör") {
                    runCommand = snippet.rendered(with: variableValues)
                    selectedID = nil
                    variableValues = [:]
                }
            }
        }
    }

    private func variableBinding(_ name: String) -> Binding<String> {
        Binding(get: { variableValues[name] ?? "" }, set: { variableValues[name] = $0 })
    }
}
