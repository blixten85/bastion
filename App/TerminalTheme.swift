#if canImport(SwiftUI)
import SwiftUI
import Foundation

/// Ett terminalfärgschema: bakgrund/text/markör/markering + 16 ANSI-färger
/// (index 0-7 normal, 8-15 bright). Färger sparas som hex-strängar (inte
/// plattformsspecifika Color-typer) så samma data går att återanvända för
/// både SwiftUI-förhandsvisning och SwiftTerms egen färgtyp i TerminalView.swift.
struct TerminalTheme: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    let ansi: [String]

    var backgroundColor: Color { Color(hex: background) }
    var foregroundColor: Color { Color(hex: foreground) }
    var cursorColor: Color { Color(hex: cursor) }
    var selectionColor: Color { Color(hex: selection) }
}

extension TerminalTheme {
    /// Alla inbyggda teman, sorterade alfabetiskt på namn för väljaren.
    /// Där källdatan saknade en egen markeringsfärg (`selection: null`)
    /// används `ansi[8]` (bright black) som ett rimligt default.
    static let all: [TerminalTheme] = [
        TerminalTheme(id: "dracula", name: "Dracula",
                      background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2", selection: "#555555",
                      ansi: ["#000000", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#bbbbbb",
                             "#555555", "#ff5555", "#50fa7b", "#f1fa8c", "#caa9fa", "#ff79c6", "#8be9fd", "#ffffff"]),
        TerminalTheme(id: "nord", name: "Nord",
                      background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#4C566A",
                      ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                             "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        TerminalTheme(id: "solarized-dark", name: "Solarized Dark",
                      background: "#002b36", foreground: "#839496", cursor: "#839496", selection: "#002b36",
                      ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                             "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        TerminalTheme(id: "solarized-light", name: "Solarized Light",
                      background: "#fdf6e3", foreground: "#586e75", cursor: "#586e75", selection: "#002b36",
                      ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                             "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        TerminalTheme(id: "gruvbox-dark", name: "Gruvbox Dark",
                      background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2", selection: "#928374",
                      ansi: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
                             "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        TerminalTheme(id: "gruvbox-light", name: "Gruvbox Light",
                      background: "#fbf1c7", foreground: "#3c3836", cursor: "#3c3836", selection: "#928374",
                      ansi: ["#fbf1c7", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#7c6f64",
                             "#928374", "#9d0006", "#79740e", "#b57614", "#076678", "#8f3f71", "#427b58", "#3c3836"]),
        TerminalTheme(id: "monokai", name: "Monokai",
                      background: "#272822", foreground: "#f8f8f2", cursor: "#f8f8f2", selection: "#75715e",
                      ansi: ["#272822", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
                             "#75715e", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"]),
        TerminalTheme(id: "one-dark", name: "One Dark",
                      background: "#282c34", foreground: "#abb2bf", cursor: "#abb2bf", selection: "#5c6370",
                      ansi: ["#1e2127", "#e06c75", "#98c379", "#d19a66", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                             "#5c6370", "#e06c75", "#98c379", "#d19a66", "#61afef", "#c678dd", "#56b6c2", "#ffffff"]),
        TerminalTheme(id: "tokyo-night", name: "Tokyo Night",
                      background: "#1a1b26", foreground: "#a9b1d6", cursor: "#a9b1d6", selection: "#444b6a",
                      ansi: ["#32344a", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#ad8ee6", "#449dab", "#787c99",
                             "#444b6a", "#ff7a93", "#b9f27c", "#ff9e64", "#7da6ff", "#bb9af7", "#0db9d7", "#acb0d0"]),
        TerminalTheme(id: "tokyo-night-storm", name: "Tokyo Night Storm",
                      background: "#24283b", foreground: "#a9b1d6", cursor: "#a9b1d6", selection: "#444b6a",
                      ansi: ["#32344a", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#ad8ee6", "#449dab", "#9699a8",
                             "#444b6a", "#ff7a93", "#b9f27c", "#ff9e64", "#7da6ff", "#bb9af7", "#0db9d7", "#acb0d0"]),
        TerminalTheme(id: "catppuccin-mocha", name: "Catppuccin Mocha",
                      background: "#1E1E2E", foreground: "#CDD6F4", cursor: "#F5E0DC", selection: "#F5E0DC",
                      ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                             "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]),
        TerminalTheme(id: "catppuccin-latte", name: "Catppuccin Latte",
                      background: "#EFF1F5", foreground: "#4C4F69", cursor: "#DC8A78", selection: "#DC8A78",
                      ansi: ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
                             "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#BCC0CC"]),
        TerminalTheme(id: "catppuccin-frappe", name: "Catppuccin Frappé",
                      background: "#303446", foreground: "#C6D0F5", cursor: "#F2D5CF", selection: "#F2D5CF",
                      ansi: ["#51576D", "#E78284", "#A6D189", "#E5C890", "#8CAAEE", "#F4B8E4", "#81C8BE", "#B5BFE2",
                             "#626880", "#E78284", "#A6D189", "#E5C890", "#8CAAEE", "#F4B8E4", "#81C8BE", "#A5ADCE"]),
        TerminalTheme(id: "catppuccin-macchiato", name: "Catppuccin Macchiato",
                      background: "#24273A", foreground: "#CAD3F5", cursor: "#F4DBD6", selection: "#F4DBD6",
                      ansi: ["#494D64", "#ED8796", "#A6DA95", "#EED49F", "#8AADF4", "#F5BDE6", "#8BD5CA", "#B8C0E0",
                             "#5B6078", "#ED8796", "#A6DA95", "#EED49F", "#8AADF4", "#F5BDE6", "#8BD5CA", "#A5ADCB"]),
        TerminalTheme(id: "ayu-dark", name: "Ayu Dark",
                      background: "#0A0E14", foreground: "#B3B1AD", cursor: "#B3B1AD", selection: "#686868",
                      ansi: ["#01060E", "#EA6C73", "#91B362", "#F9AF4F", "#53BDFA", "#FAE994", "#90E1C6", "#C7C7C7",
                             "#686868", "#F07178", "#C2D94C", "#FFB454", "#59C2FF", "#FFEE99", "#95E6CB", "#FFFFFF"]),
        TerminalTheme(id: "ayu-light", name: "Ayu Light",
                      background: "#FCFCFC", foreground: "#5C6166", cursor: "#5C6166", selection: "#343434",
                      ansi: ["#010101", "#e7666a", "#80ab24", "#eba54d", "#4196df", "#9870c3", "#51b891", "#c1c1c1",
                             "#343434", "#ee9295", "#9fd32f", "#f0bc7b", "#6daee6", "#b294d2", "#75c7a8", "#dbdbdb"]),
        TerminalTheme(id: "everforest-dark", name: "Everforest Dark",
                      background: "#2d353b", foreground: "#d3c6aa", cursor: "#d3c6aa", selection: "#475258",
                      ansi: ["#475258", "#e67e80", "#a7c080", "#dbbc7f", "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa",
                             "#475258", "#e67e80", "#a7c080", "#dbbc7f", "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa"]),
        TerminalTheme(id: "rose-pine", name: "Rosé Pine",
                      background: "#191724", foreground: "#e0def4", cursor: "#524f67", selection: "#403d52",
                      ansi: ["#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
                             "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4"]),
        TerminalTheme(id: "kanagawa", name: "Kanagawa",
                      background: "#1f1f28", foreground: "#dcd7ba", cursor: "#dcd7ba", selection: "#2d4f67",
                      ansi: ["#090618", "#c34043", "#76946a", "#c0a36e", "#7e9cd8", "#957fb8", "#6a9589", "#c8c093",
                             "#727169", "#e82424", "#98bb6c", "#e6c384", "#7fb4ca", "#938aa9", "#7aa89f", "#dcd7ba"]),
        TerminalTheme(id: "nightfox", name: "Nightfox",
                      background: "#192330", foreground: "#cdcecf", cursor: "#aeafb0", selection: "#2b3b51",
                      ansi: ["#393b44", "#c94f6d", "#81b29a", "#dbc074", "#719cd6", "#9d79d6", "#63cdcf", "#dfdfe0",
                             "#575860", "#d16983", "#8ebaa4", "#e0c989", "#86abdc", "#baa1e2", "#7ad5d6", "#e4e4e5"]),
        TerminalTheme(id: "gruvbox-material", name: "Gruvbox Material",
                      background: "#282828", foreground: "#dfbf8e", cursor: "#dfbf8e", selection: "#928374",
                      ansi: ["#665c54", "#ea6962", "#a9b665", "#e78a4e", "#7daea3", "#d3869b", "#89b482", "#dfbf8e",
                             "#928374", "#ea6962", "#a9b665", "#e3a84e", "#7daea3", "#d3869b", "#89b482", "#dfbf8e"]),
        TerminalTheme(id: "oxocarbon", name: "Oxocarbon",
                      background: "#1b1b1b", foreground: "#ffffff", cursor: "#78a9ff", selection: "#525252",
                      ansi: ["#161616", "#ee5396", "#42be65", "#ff7eb6", "#33b1ff", "#be95ff", "#3ddbd9", "#ffffff",
                             "#525252", "#ee5396", "#42be65", "#ff7eb6", "#33b1ff", "#be95ff", "#3ddbd9", "#ffffff"]),
        TerminalTheme(id: "tomorrow-night", name: "Tomorrow Night",
                      background: "#1d1f21", foreground: "#c5c8c6", cursor: "#ffffff", selection: "#666666",
                      ansi: ["#1d1f21", "#cc6666", "#b5bd68", "#e6c547", "#81a2be", "#b294bb", "#70c0ba", "#373b41",
                             "#666666", "#ff3334", "#9ec400", "#f0c674", "#81a2be", "#b77ee0", "#54ced6", "#282a2e"]),
        TerminalTheme(id: "base16-default-dark", name: "Base16 Default Dark",
                      background: "#181818", foreground: "#d8d8d8", cursor: "#d8d8d8", selection: "#585858",
                      ansi: ["#181818", "#ab4642", "#a1b56c", "#f7ca88", "#7cafc2", "#ba8baf", "#86c1b9", "#d8d8d8",
                             "#585858", "#ab4642", "#a1b56c", "#f7ca88", "#7cafc2", "#ba8baf", "#86c1b9", "#f8f8f8"]),
        TerminalTheme(id: "material-theme", name: "Material Theme",
                      background: "#1e282d", foreground: "#c4c7d1", cursor: "#c4c7d1", selection: "#666666",
                      ansi: ["#666666", "#eb606b", "#c3e88d", "#f7eb95", "#80cbc4", "#ff2f90", "#aeddff", "#ffffff",
                             "#ff262b", "#eb606b", "#c3e88d", "#f7eb95", "#7dc6bf", "#6c71c4", "#35434d", "#ffffff"]),
    ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static let defaultTheme: TerminalTheme = all.first { $0.id == "dracula" } ?? all[0]

    /// Slår upp temat för ett sparat id; faller tillbaka på `defaultTheme` om
    /// id saknas eller inte längre finns bland `all`.
    static func theme(id: String?) -> TerminalTheme {
        guard let id, let match = all.first(where: { $0.id == id }) else { return defaultTheme }
        return match
    }
}

extension Color {
    /// Bygger en SwiftUI-`Color` ur en "#RRGGBB"-hexsträng. Ogiltig indata
    /// faller tillbaka på svart snarare än att krascha.
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString.removeAll { $0 == "#" }
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
#endif
