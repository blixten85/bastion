// Bara macOS: `Sources/SSHCore/Serial.swift` exponerar `SerialConfig`/
// `SerialSession` enbart på `os(macOS) || os(Linux)` (App/ har inget
// Linux-mål, bara iOS+macOS) — iOS saknar meningsfull USB-serial-åtkomst
// utan ett separat MFi/External Accessory-arbete, se den filens
// dokumentation för fullständigt resonemang.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI
import SSHCore

/// `.cover(item:)`/`.sheet(item:)` kräver `Identifiable` — samma mönster
/// som `TelnetTarget`s motsvarande extension i TelnetConnectView.swift.
extension SerialConfig: Identifiable {
    public var id: String { "\(path):\(baudRate)" }
}

/// Ansluter till en seriell/USB-enhet — gap-listepost #8 i
/// [[project-bastion-termius-parity-mandate]]. Mest relevant på macOS
/// (`Sources/SSHCore/Serial.swift` är `#if os(macOS) || os(Linux)`, se den
/// filen för varför iOS/Windows medvetet saknas). Ingen värdlagring (samma
/// resonemang som Telnet/Quick Connect — en fysisk port är inte en
/// nätverksvärd att spara/återansluta till på samma sätt).
struct SerialConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var availablePaths: [String] = SerialPortLister.availablePaths()
    @State private var selectedPath: String?
    @State private var customPath = ""
    @State private var baudRate: UInt32 = 9600
    let onConnect: (SerialConfig) -> Void

    private var effectivePath: String {
        selectedPath ?? customPath.trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool { !effectivePath.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Port") {
                    if availablePaths.isEmpty {
                        Text("Inga seriella enheter hittades — ange sökvägen manuellt nedan.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Picker("Enhet", selection: $selectedPath) {
                            Text("Ange manuellt").tag(String?.none)
                            ForEach(availablePaths, id: \.self) { path in
                                Text(path).tag(String?.some(path))
                            }
                        }
                    }
                    if selectedPath == nil {
                        TextField("Sökväg (t.ex. /dev/cu.usbserial-1410)", text: $customPath)
                            .noAutocap().autocorrectionDisabled()
                    }
                }
                Section("Hastighet") {
                    Picker("Baudhastighet", selection: $baudRate) {
                        ForEach(SerialSession.commonBaudRates, id: \.self) { rate in
                            Text("\(rate)").tag(rate)
                        }
                    }
                }
                Section {
                    Button {
                        availablePaths = SerialPortLister.availablePaths()
                    } label: {
                        Label("Sök igen", systemImage: "arrow.clockwise")
                    }
                }
            }
            .navigationTitle("Seriell anslutning")
            .navInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Avbryt") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Anslut") { connect() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func connect() {
        onConnect(SerialConfig(path: effectivePath, baudRate: baudRate))
        dismiss()
    }
}

#if canImport(SwiftTerm)
/// Fullskärmscover-vy för en aktiv seriell session, motsvarar
/// `TelnetSessionView`/`SessionView`.
struct SerialSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let config: SerialConfig

    var body: some View {
        NavigationStack {
            BastionSerialTerminal(config: config)
                .ignoresSafeArea(.container, edges: .bottom)
                .background(Color.black)
                .navigationTitle(config.path)
                .navInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Klar") { dismiss() }
                    }
                }
        }
    }
}
#endif
#endif
