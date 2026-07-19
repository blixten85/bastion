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
    private let target: TelnetTarget
    private var session: TelnetSession?
    private var isStopped = false
    /// Bytes i slutet av en mottagen chunk som är en OFULLSTÄNDIG UTF-8-
    /// sekvens (t.ex. en flerbyte-tecken delad mitt itu över två TCP-
    /// paket) — sparas och slås ihop med nästa chunk istället för att
    /// avkodas för tidigt till `U+FFFD` (cubic-fynd, denna PR).
    private var pendingBytes: [UInt8] = []

    init(target: TelnetTarget, cols: Int = 100, rows: Int = 30) {
        self.buffer = TerminalBuffer(cols: cols, rows: rows)
        self.target = target
    }

    func start() async {
        do {
            let session = try await TelnetSession.connect(target: target)
            guard !isStopped else { await session.close(); return }
            self.session = session
            for try await bytes in session.output {
                guard !isStopped else { break }
                pendingBytes.append(contentsOf: bytes)
                let (complete, remainder) = Self.splitTrailingIncompleteUTF8(pendingBytes)
                if !complete.isEmpty { buffer.feed(String(decoding: complete, as: UTF8.self)) }
                pendingBytes = remainder
            }
            flushPendingBytes()
            if !isStopped { await session.close() }
        } catch {
            flushPendingBytes()
            if !isStopped { await self.session?.close() }
            guard !isStopped else { return }
            buffer.feed("\r\n[bastion] fel: \(error)\r\n")
        }
    }

    /// Strömmen (normalt eller via fel) kan ta slut med en ofullständig
    /// flerbyte-sekvens fortfarande kvar i `pendingBytes` — utan denna
    /// tappas svansen tyst istället för att visas (cubic-fynd, denna PR).
    private func flushPendingBytes() {
        guard !pendingBytes.isEmpty else { return }
        buffer.feed(String(decoding: pendingBytes, as: UTF8.self))
        pendingBytes = []
    }

    /// Letar EXPLICIT efter en giltig flerbyte-ledbyte (0xC0–0xF7) bland de
    /// sista 1–4 byten. Bara om en sådan hittas OCH den inte redan har fått
    /// alla sina fortsättningsbyte hålls svansen kvar till nästa chunk —
    /// annars (ren ASCII, en redan komplett sekvens, eller lösryckta
    /// fortsättningsbyte UTAN någon ledbyte inom räckhåll — trasig indata)
    /// är hela `bytes` "komplett" och avkodas direkt. Detta var föregående
    /// version FEL på åt båda hållen: den avkodade riktiga delade sekvenser
    /// för tidigt (cubic-fynd 1) OCH senare höll kvar lösryckta
    /// fortsättningsbyte i evighet på en tyst men öppen session tills
    /// anslutningen stängdes (cubic-fynd 2) — den enda korrekta regeln är
    /// att bara vänta när en FAKTISK ledbyte hittats med för få byte kvar.
    private static func splitTrailingIncompleteUTF8(_ bytes: [UInt8]) -> (complete: [UInt8], remainder: [UInt8]) {
        let maxLookback = min(4, bytes.count)
        guard maxLookback > 0 else { return (bytes, []) }
        for lookback in 1...maxLookback {
            let lead = bytes.count - lookback
            let leadByte = bytes[lead]
            let expectedLength: Int
            switch leadByte {
            case 0xC0...0xDF: expectedLength = 2
            case 0xE0...0xEF: expectedLength = 3
            case 0xF0...0xF7: expectedLength = 4
            default: continue // ASCII eller fortsättningsbyte — inte en ledbyte, fortsätt leta bakåt
            }
            if lookback < expectedLength {
                return (Array(bytes[0..<lead]), Array(bytes[lead...]))
            }
            break // ledbyte hittad men sekvensen är redan komplett (eller ogiltigt lång) — inget att hålla kvar
        }
        return (bytes, [])
    }

    // RFC 854 (NVT): en rads slut är CR LF, inte en bar CR — vissa striktare
    // Telnet-servrar (nätverksutrustning) förkastar annars kommandot.
    func sendLine(_ text: String) { session?.send(text + "\r\n") }
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
