#if canImport(SwiftUI)
import SwiftUI

/// Väljare för terminalens färgtema — sparas i UserDefaults under
/// `TerminalThemeKeys.selectedID` (se App/TerminalView.swift) och läses av
/// nästa gång en terminalvy öppnas. Ingen live-omritning av redan öppna
/// sessioner; samma "gäller vid nästa anslutning"-mönster som andra
/// inställningar i appen.
struct TerminalThemeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TerminalThemeKeys.selectedID) private var selectedID = TerminalTheme.defaultTheme.id

    var body: some View {
        NavigationStack {
            List(TerminalTheme.all) { theme in
                Button {
                    selectedID = theme.id
                } label: {
                    HStack(spacing: 12) {
                        ThemeSwatch(theme: theme)
                        Text(theme.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if theme.id == selectedID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Terminaltema")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klar") { dismiss() }
                }
            }
        }
    }
}

/// Liten förhandsvisning: bakgrund + fyra ANSI-färger som prickar.
private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(theme.backgroundColor)
            .frame(width: 44, height: 28)
            .overlay(
                HStack(spacing: 3) {
                    ForEach([1, 2, 4, 3], id: \.self) { idx in
                        Circle()
                            .fill(Color(hex: theme.ansi[idx]))
                            .frame(width: 5, height: 5)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3), lineWidth: 1)
            )
    }
}
#endif
