#if canImport(SwiftUI)
import SwiftUI
import SSHCore

/// Klistra in en `~/.ssh/config` för att importera värdar. (iOS har ingen
/// `~/.ssh`, så inklistring/dokumentväljare är vägen in.)
struct ImportConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onImport: (String) -> Int   // returnerar antal importerade

    @State private var result: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("Klistra in innehållet i din ssh-config:")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .noAutocap()
                    .border(Color.secondary.opacity(0.3))
                    .padding(.horizontal)
                if let result { Text(result).font(.footnote).padding(.horizontal) }
            }
            .navigationTitle("Importera")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importera") {
                        let n = onImport(text)
                        result = "Importerade \(n) värd(ar)."
                        if n > 0 { dismiss() }
                    }.disabled(text.isEmpty)
                }
            }
        }
    }
}
#endif
