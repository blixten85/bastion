#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Bläddringsbart referensbibliotek (Docker/Linux/Git/Cloudflare/Tailscale/
/// WireGuard/systemd) — VISION.md "Command Library". Ren, statisk data
/// (`CommandLibrary.all`), ingen egen lagring. Kör ett kommando genom samma
/// variabelifyllning som Snippets (`CommandLibraryEntry.asSnippet`).
struct CommandLibraryView: View {
    let request: ConnectRequest
    /// Vidarebefordras till `SessionView` för jump-host-uppslagning. `nil`
    /// på anropsplatser som saknar en delad store (ingen regression, se
    /// `SessionView.store`).
    var store: HostStore? = nil
    @State private var running: CommandLibraryEntry?
    @State private var runningRequest: ConnectRequest?

    var body: some View {
        List {
            ForEach(CommandLibraryEntry.Category.allCases, id: \.self) { category in
                let entries = CommandLibrary.entries(in: category)
                if !entries.isEmpty {
                    Section(category.rawValue) {
                        ForEach(entries) { entry in
                            Button { running = entry } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.summary).font(.body.weight(.medium))
                                    Text(entry.command).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Kommandobibliotek")
        .navInlineTitle()
        .sheet(item: $running) { entry in
            SnippetRunView(
                snippet: entry.asSnippet,
                onRun: { command in
                    running = nil
                    runningRequest = request.running(command)
                },
                onCancel: { running = nil },
                detail: runDetail(for: entry)
            )
        }
        .cover(item: $runningRequest) { req in
            SessionView(request: req, store: store)
        }
    }

    private func runDetail(for entry: CommandLibraryEntry) -> String? {
        var parts: [String] = []
        if let example = entry.example { parts.append("Exempel: \(example)") }
        if let docsURL = entry.docsURL { parts.append("Dokumentation: \(docsURL)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
#endif
