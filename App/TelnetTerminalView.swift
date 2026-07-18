#if canImport(SwiftTerm) && (os(iOS) || os(macOS))
import SwiftTerm
import SwiftUI
import SSHCore
import Foundation

// XCODE-ONLY, samma begränsning som TerminalView.swift (SwiftTerm kräver
// UIKit/AppKit). Speglar SSHTerminalController/BastionTerminal-mönstret
// rakt av, men driven av TelnetSession istället för SSHShell — Telnet delar
// ingen kod med SSH-lagret (helt olika protokoll, se Sources/SSHCore/Telnet.swift).
//
// Känd begränsning: ingen storleksförhandling (RFC 1073 NAWS) — vår
// TelnetIACFilter refuserar ALLA förhandlade alternativ medvetet (enklast
// möjliga korrekta klientbeteende), så terminalstorlek skickas aldrig till
// fjärrsidan. De flesta Telnet-servrar (nätverksutrustning) hanterar det
// fint med en fast standardbredd; en riktig NAWS-implementation kan läggas
// till senare om det visar sig behövas.

/// Äger Telnet-anslutningen, pumpar utdata till en sink och tar emot
/// tangenttryck. Testbar utan UI (speglar `SSHTerminalController`).
@MainActor
final class TelnetTerminalController {
    private let target: TelnetTarget
    private var session: TelnetSession?
    /// Se `SSHTerminalController.isStopped` — samma resonemang: en sen
    /// connect() som landar EFTER stop() ska stänga det den just öppnade
    /// istället för att bli en föräldralös session.
    private var isStopped = false

    var onData: ((ArraySlice<UInt8>) -> Void)?

    init(target: TelnetTarget) {
        self.target = target
    }

    func start() {
        Task {
            do {
                let session = try await TelnetSession.connect(target: target)
                self.session = session
                guard !isStopped else { await session.close(); return }
                for try await bytes in session.output {
                    guard !isStopped else { break }
                    self.onData?(bytes[...])
                }
            } catch {
                guard !isStopped else { return }
                let msg = Array("\r\n[bastion] fel: \(error)\r\n".utf8)
                self.onData?(msg[...])
            }
        }
    }

    func sendKeys(_ data: ArraySlice<UInt8>) { session?.send(Array(data)) }
    func stop() {
        isStopped = true
        let session = self.session
        Task { await session?.close() }
    }
}

struct BastionTelnetTerminal: TerminalRepresentable {
    let target: TelnetTarget

    func makeCoordinator() -> Coordinator {
        Coordinator(target: target)
    }

    private func build(_ context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    #if os(iOS)
    func makeUIView(context: Context) -> TerminalView { build(context) }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.tearDown()
    }
    #else
    func makeNSView(context: Context) -> TerminalView { build(context) }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.tearDown()
    }
    #endif

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let controller: TelnetTerminalController
        private weak var view: TerminalView?

        init(target: TelnetTarget) {
            self.controller = TelnetTerminalController(target: target)
            super.init()
            controller.onData = { [weak self] bytes in
                self?.view?.feed(byteArray: bytes)
            }
        }

        func attach(_ view: TerminalView) {
            self.view = view
            let savedID = UserDefaults.standard.string(forKey: TerminalThemeKeys.selectedID)
            view.apply(theme: TerminalTheme.theme(id: savedID))
            controller.start()
        }

        /// Se `BastionTerminal.Coordinator.tearDown()` — samma resonemang.
        func tearDown() {
            controller.stop()
            view = nil
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            controller.sendKeys(data)
        }

        // Ingen NAWS-förhandling — se filkommentaren ovan. Storleksändringar
        // skickas aldrig till fjärrsidan, bara terminalvyn själv ritar om.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
