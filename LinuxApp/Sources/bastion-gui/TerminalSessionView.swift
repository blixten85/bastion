import Foundation
import SSHCore
import SwiftCrossUI

/// En bestående PTY-shell (miljö/cwd bevaras mellan kommandon, till skillnad
/// från `execute()` per kommando) med VT100-rendering via `TerminalBuffer`.
///
/// SwiftCrossUI har ingen rå tangentbords-API (inget piltangent-/Ctrl-event),
/// så inmatning är rad-i-taget via `TextField` + Enter. De vanligaste kontrolltangenterna
/// (piltangenter, Tab, Esc, Ctrl+C, Ctrl+D) finns som egna knappar och skickas
/// som rå bytes direkt — så navigering i t.ex. `htop`/`less` fungerar ändå,
/// även om löpande texttangenttryckning inte gör det.
@MainActor
final class TerminalController: ObservableObject {
    // @Published (trots att den aldrig byts ut) så att buffer.revision-ändringar
    // länkas in i controllerns egna didChange — annars märker `@State`-vyn
    // ovanför aldrig att terminalinnehållet uppdaterats.
    @Published var buffer: TerminalBuffer
    @Published var statusMessage: String?
    private let host: Host
    private let password: String?
    /// Skickas till shellen direkt efter att den öppnats (t.ex. `docker exec …`).
    private let initialCommand: String?
    private var session: SSHSession?
    private var shell: SSHShell?

    init(host: Host, password: String?, initialCommand: String? = nil, cols: Int = 100, rows: Int = 30) {
        self.buffer = TerminalBuffer(cols: cols, rows: rows)
        self.host = host
        self.password = password
        self.initialCommand = initialCommand
    }

    func start() async {
        guard let auth = resolveAuth(for: host, password: password) else {
            statusMessage = "Kan inte autentisera värden."
            return
        }
        let session = SSHSession(target: host.target, auth: auth)
        self.session = session
        do {
            try await session.connect()
            let shell = try await session.openShell(cols: buffer.cols, rows: buffer.rowCount)
            self.shell = shell
            statusMessage = nil
            if let initialCommand { shell.send(initialCommand + "\r") }
            for try await chunk in shell.output {
                buffer.feed(chunk.text)
            }
        } catch {
            buffer.feed("\r\n[bastion] fel: \(error)\r\n")
        }
    }

    func sendLine(_ text: String) {
        guard !text.isEmpty else { return }
        shell?.send(text + "\r")
    }

    func sendRaw(_ text: String) {
        shell?.send(text)
    }

    func stop() {
        shell?.close()
        let session = self.session
        Task { await session?.close() }
    }
}

struct TerminalSessionView: View {
    @State private var controller: TerminalController
    @State private var input = ""

    init(host: Host, password: String?, initialCommand: String? = nil) {
        self._controller = State(wrappedValue: TerminalController(host: host, password: password, initialCommand: initialCommand))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminal").font(.headline)
            if let status = controller.statusMessage {
                Text(status).foregroundColor(.red)
            }
            ScrollView {
                TerminalGridView(buffer: controller.buffer)
            }
            .frame(minHeight: 320)

            controlKeyRow

            HStack {
                TextField("Kommando…", text: $input)
                    .onSubmit { submit() }
                Button("Skicka") { submit() }
                    .disabled(input.isEmpty)
            }
        }
        .padding()
        .task { await controller.start() }
        .onDisappear { controller.stop() }
    }

    private func submit() {
        controller.sendLine(input)
        input = ""
    }

    private var controlKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Esc") { controller.sendRaw("\u{1B}") }
                Button("Tab") { controller.sendRaw("\t") }
                Button("←") { controller.sendRaw("\u{1B}[D") }
                Button("↑") { controller.sendRaw("\u{1B}[A") }
                Button("↓") { controller.sendRaw("\u{1B}[B") }
                Button("→") { controller.sendRaw("\u{1B}[C") }
                Button("Ctrl+C") { controller.sendRaw("\u{03}") }
                Button("Ctrl+D") { controller.sendRaw("\u{04}") }
            }
            HStack(spacing: 6) {
                // Home/End/PgUp/PgDn: standard xterm-sekvenser. Space skickas
                // direkt (inte via textfältet) för sidbläddring i less/more/man.
                Button("Home") { controller.sendRaw("\u{1B}[H") }
                Button("End") { controller.sendRaw("\u{1B}[F") }
                Button("PgUp") { controller.sendRaw("\u{1B}[5~") }
                Button("PgDn") { controller.sendRaw("\u{1B}[6~") }
                Button("Space") { controller.sendRaw(" ") }
            }
        }
    }
}
