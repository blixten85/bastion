#if canImport(SwiftTerm) && (os(iOS) || os(macOS))
import SwiftTerm
import SwiftUI
import SSHCore
import Foundation
#if os(iOS)
import Sentry
#endif

// XCODE-ONLY. Byggs inte av SwiftPM på Linux (SwiftTerm kräver UIKit/AppKit).
// Lägg till SwiftTerm som paketberoende i Xcode:
//   https://github.com/migueldeicaza/SwiftTerm  (MIT)
//
// Kopplar SSHCore.SSHShell (interaktiv PTY-shell) till en riktig SwiftTerm-vy:
//   fjärr-stdout  -> terminalView.feed
//   tangenttryck  -> shell.send
//   storleksändr. -> shell.resize
//
// Not: TerminalViewDelegate-protokollet har fler metoder i vissa SwiftTerm-
// versioner (clipboardCopy, requestOpenLink, bell, iTermContent …). Lägg till
// tomma stubbar för dem som din version kräver — kärnkopplingen nedan är den
// som betyder något.

/// Version-oberoende koppling: äger anslutningen och shellen, pumpar utdata
/// till en sink och tar emot tangenttryck/storlek. Testbar utan UI.
@MainActor
final class SSHTerminalController {
    private let target: SSHTarget
    private let auth: SSHAuth
    private var session: SSHSession?
    private var shell: SSHShell?
    /// Sätts av stop(). Kollas efter varje await-punkt i start() så en sen
    /// connect()/openShell() som landar EFTER teardown stänger det den just
    /// öppnade istället för att bli en föräldralös, aldrig stängd session
    /// (CodeRabbit-fynd på #155: stop() stänger bara det som redan hunnit
    /// tilldelas self.session/self.shell VID ANROPSTILLFÄLLET).
    private var isStopped = false

    /// Anropas på main med bytes att mata in i terminalvyn.
    var onData: ((ArraySlice<UInt8>) -> Void)?
    /// Skickas till shellen direkt efter att den öppnats (t.ex. `docker exec …`).
    var initialCommand: String?

    init(target: SSHTarget, auth: SSHAuth, initialCommand: String? = nil) {
        self.target = target
        self.auth = auth
        self.initialCommand = initialCommand
    }

    func start(cols: Int, rows: Int) {
        Task {
            do {
                let session = SSHSession(target: target, auth: auth)
                self.session = session
                try await session.connect()
                guard !isStopped else { await session.close(); return }
                let shell = try await session.openShell(cols: cols, rows: rows)
                guard !isStopped else { shell.close(); return }
                self.shell = shell
                if let cmd = initialCommand { shell.send(cmd + "\n") }
                #if os(iOS)
                // Bara händelsekategorin, aldrig host/user/kommando-innehåll
                // - samma integritetsprincip som session replay redan följer
                // (se init() i BastionApp.swift).
                SentrySDK.logger.info("ssh.session.started")
                #endif
                for try await chunk in shell.output {
                    guard !isStopped else { break }
                    let bytes = chunk.bytes
                    self.onData?(bytes[...])
                }
            } catch {
                guard !isStopped else { return }
                #if os(iOS)
                SentrySDK.logger.warn("ssh.session.failed", attributes: ["category": String(describing: type(of: error))])
                #endif
                let msg = Array("\r\n[bastion] fel: \(error)\r\n".utf8)
                self.onData?(msg[...])
            }
        }
    }

    func sendKeys(_ data: ArraySlice<UInt8>) { shell?.send(Array(data)) }
    func resize(cols: Int, rows: Int) { shell?.resize(cols: cols, rows: rows) }
    func stop() {
        isStopped = true
        shell?.close()
        let session = self.session
        Task { await session?.close() }
    }
}

private extension SwiftTerm.Color {
    /// Bygger en SwiftTerm-färg ur en "#RRGGBB"-hexsträng (så som Bastions
    /// teman lagras i TerminalTheme.swift). SwiftTerm.Color-komponenter är
    /// 0-65535, så 8-bitarskomponenter (0-255) skalas upp med 257
    /// (255 * 257 == 65535).
    convenience init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString.removeAll { $0 == "#" }
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        let r = UInt16((value & 0xFF0000) >> 16)
        let g = UInt16((value & 0x00FF00) >> 8)
        let b = UInt16(value & 0x0000FF)
        self.init(red: r * 257, green: g * 257, blue: b * 257)
    }
}

extension TerminalView {
    /// Applicerar ett Bastion-terminaltema: bakgrund/text/markör/markering +
    /// de 16 ANSI-färgerna. `installColors` uppdaterar både färgmotorn och
    /// om-renderar existerande innehåll (se SwiftTerm.TerminalView).
    func apply(theme: TerminalTheme) {
        nativeBackgroundColor = TTColor.make(color: SwiftTerm.Color(hex: theme.background))
        nativeForegroundColor = TTColor.make(color: SwiftTerm.Color(hex: theme.foreground))
        caretColor = TTColor.make(color: SwiftTerm.Color(hex: theme.cursor))
        selectedTextBackgroundColor = TTColor.make(color: SwiftTerm.Color(hex: theme.selection))
        installColors(theme.ansi.map { SwiftTerm.Color(hex: $0) })
    }
}

#if os(iOS)
typealias TerminalRepresentable = UIViewRepresentable
#else
typealias TerminalRepresentable = NSViewRepresentable
#endif

struct BastionTerminal: TerminalRepresentable {
    let target: SSHTarget
    let auth: SSHAuth
    var initialCommand: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(target: target, auth: auth, initialCommand: initialCommand)
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
        private let controller: SSHTerminalController
        private weak var view: TerminalView?

        init(target: SSHTarget, auth: SSHAuth, initialCommand: String?) {
            self.controller = SSHTerminalController(target: target, auth: auth, initialCommand: initialCommand)
            super.init()
            controller.onData = { [weak self] bytes in
                self?.view?.feed(byteArray: bytes)
            }
        }

        func attach(_ view: TerminalView) {
            self.view = view
            let savedID = UserDefaults.standard.string(forKey: TerminalThemeKeys.selectedID)
            view.apply(theme: TerminalTheme.theme(id: savedID))
            let t = view.getTerminal()
            controller.start(cols: t.cols, rows: t.rows)
        }

        /// Anropas av dismantleUIView/dismantleNSView när vyn tas bort ur
        /// hierarkin. Utan denna fortsätter bakgrunds-Task:en i controller.start()
        /// köra och mata feed() på en föräldralös vy efter dismiss — till skillnad
        /// från PortForwardView/DockerView/SFTPBrowserView, som redan städar via
        /// .onDisappear { model.disconnect() }.
        func tearDown() {
            controller.stop()
            view = nil
        }

        // Tangenttryck från terminalen -> fjärr-shell.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            controller.sendKeys(data)
        }

        // Terminalen ändrade storlek -> meddela fjärrsidan.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            controller.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
