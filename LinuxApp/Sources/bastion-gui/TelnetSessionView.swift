import Foundation
import SSHCore
import SwiftCrossUI

/// Telnet-motsvarigheten till `TerminalController`/`TerminalSessionView` —
/// samma VT100-rendering via `TerminalBuffer`, men driven av `TelnetSession`
/// istället för `SSHShell`. Telnet delar ingen kod med SSH-lagret (helt olika
/// protokoll, se Sources/SSHCore/Telnet.swift). Speglar även
/// App/TelnetTerminalView.swifts teardown-mönster (isStopped-kollar efter
/// varje await-punkt).
@MainActor
final class TelnetSessionController: ObservableObject {
    @Published var buffer: TerminalBuffer
    @Published var statusMessage: String?
    private let target: TelnetTarget
    private var session: TelnetSession?
    private var isStopped = false

    init(target: TelnetTarget, cols: Int = 100, rows: Int = 30) {
        self.buffer = TerminalBuffer(cols: cols, rows: rows)
        self.target = target
    }

    func start() async {
        do {
            let session = try await TelnetSession.connect(target: target)
            guard !isStopped else { await session.close(); return }
            self.session = session
            statusMessage = nil
            for try await bytes in session.output {
                guard !isStopped else { break }
                buffer.feed(String(decoding: bytes, as: UTF8.self))
            }
            if !isStopped { await session.close() }
        } catch {
            if !isStopped { await self.session?.close() }
            guard !isStopped else { return }
            buffer.feed("\r\n[bastion] fel: \(error)\r\n")
        }
    }

    func sendLine(_ text: String) { session?.send(text + "\r") }
    func sendRaw(_ text: String) { session?.send(text) }

    func stop() {
        isStopped = true
        let session = self.session
        Task { await session?.close() }
    }
}

struct TelnetSessionView: View {
    @State private var controller: TelnetSessionController
    @State private var input = ""
    let onClose: () -> Void

    init(target: TelnetTarget, onClose: @escaping () -> Void) {
        self._controller = State(wrappedValue: TelnetSessionController(target: target))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Telnet").font(.headline)
                Spacer()
                Button("Klar") { controller.stop(); onClose() }
            }
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
                Button("Skicka") { submit() }.disabled(input.isEmpty)
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
                Button("Home") { controller.sendRaw("\u{1B}[H") }
                Button("End") { controller.sendRaw("\u{1B}[F") }
                Button("PgUp") { controller.sendRaw("\u{1B}[5~") }
                Button("PgDn") { controller.sendRaw("\u{1B}[6~") }
                Button("Space") { controller.sendRaw(" ") }
            }
        }
    }
}
