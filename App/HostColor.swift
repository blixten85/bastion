#if canImport(SwiftUI)
import SwiftUI

/// Fast palett för `Host.colorTag` — sparas som namn (String) i host-DB:n, inte
/// en plattformsspecifik Color, så den kan synkas och läsas av LinuxApp också.
enum HostColorPalette {
    static let names: [String] = ["red", "orange", "yellow", "green", "blue", "purple", "gray"]

    static func color(for name: String?) -> Color? {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "gray": return .gray
        default: return nil
        }
    }
}

/// Rad av färgcirklar — tryck för att välja, tryck igen på vald för att ta bort.
struct HostColorPicker: View {
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(HostColorPalette.names, id: \.self) { name in
                Circle()
                    .fill(HostColorPalette.color(for: name) ?? .clear)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle().stroke(.primary, lineWidth: selection == name ? 2 : 0)
                    )
                    .onTapGesture {
                        selection = (selection == name) ? nil : name
                    }
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
