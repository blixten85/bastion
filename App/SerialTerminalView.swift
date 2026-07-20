// Bara macOS — se filkommentaren i SerialConnectView.swift/Serial.swift.
#if canImport(SwiftTerm) && os(macOS)
import SwiftTerm
import SwiftUI
import SSHCore
import Foundation

// XCODE-ONLY, samma begränsning som TerminalView.swift/TelnetTerminalView.swift
// (SwiftTerm kräver AppKit). Speglar TelnetTerminalController rakt av, driven
// av SerialSession istället för TelnetSession.
//
// Känd begränsning: ingen storleksförhandling — en seriell port har inget
// motsvarande NAWS-koncept (den är inte ett förhandlingsbart protokoll,
// bara en rå byteström), så terminalstorlek är alltid den lokala vyns.

/// Äger den seriella anslutningen, pumpar utdata till en sink och tar emot
/// tangenttryck. Testbar utan UI (speglar `TelnetTerminalController`).
@MainActor
final class SerialTerminalController {
    private let config: SerialConfig
    private var session: SerialSession?
    /// Se `TelnetTerminalController.isStopped`/`SSHTerminalController.isStopped`
    /// — samma resonemang: en sen connect() som landar EFTER stop() ska
    /// stänga det den just öppnade istället för att bli en föräldralös session.
    private var isStopped = false

    var onData: ((ArraySlice<UInt8>) -> Void)?

    init(config: SerialConfig) {
        self.config = config
    }

    func start() {
        Task {
            do {
                let session = try await SerialSession.connect(config: config)
                self.session = session
                guard !isStopped else { await session.close(); return }
                for try await bytes in session.output {
                    guard !isStopped else { break }
                    self.onData?(bytes[...])
                }
                // Se TelnetTerminalController.start() — samma resonemang: en
                // ström som tar slut normalt utan att stop() körts skulle
                // annars läcka event loop-gruppens tråd tills vyn dismissas.
                if !isStopped { await session.close() }
            } catch {
                if !isStopped { await self.session?.close() }
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

struct BastionSerialTerminal: TerminalRepresentable {
    let config: SerialConfig

    func makeCoordinator() -> Coordinator {
        Coordinator(config: config)
    }

    private func build(_ context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func makeNSView(context: Context) -> TerminalView { build(context) }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let controller: SerialTerminalController
        private weak var view: TerminalView?

        init(config: SerialConfig) {
            self.controller = SerialTerminalController(config: config)
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

        func tearDown() {
            controller.stop()
            view = nil
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            controller.sendKeys(data)
        }

        // Ingen storleksförhandling — se filkommentaren ovan.
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
