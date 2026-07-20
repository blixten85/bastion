#if canImport(SwiftUI)
import SSHCore

/// Litet hjälpfel för `connect`-closures som vill avbryta med ett färdigt
/// användarmeddelande (t.ex. "kan inte autentisera") utan att det
/// formateras om av `SSHError`s enum-baserade standardbeskrivning när
/// `onError` gör `"\(error)"`.
struct PlainMessageError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Delad livscykelhanterare för en lazy, cachad SSH-anslutning som flera
/// åtgärder på samma vy kan använda samtidigt (refresh/act/browse ...).
///
/// Bakgrund: `DockerModel`, `PortForwardModel` och `SFTPBrowserModel`
/// implementerade tidigare EXAKT samma mönster var för sig (cache pågående
/// anslutningsförsök, avbryt vid `disconnect()`, kolla identitet efter
/// `await` för att upptäcka en teardown som hann köra under tiden). Den
/// största delen av granskningsfynden på PR #172 var samma livscykelbugg
/// återupptäckt i tre separata kopior (t.ex. `DockerModel` saknade länge
/// samma omkontroll `PortForwardModel` redan hade). Den här typen är den
/// enda platsen mönstret nu behöver underhållas (cubic #30).
@MainActor
final class ChainConnector<Client: AnyObject> {
    private var chain: SSHConnectionChain?
    // Se kommentaren i `ensure(...)`: ger `disconnect()` något att stänga
    // under FÖNSTRET mellan att `connect()` lyckats och `open(_:)` (ett ev.
    // extra öppningssteg ovanpå kedjan, t.ex. `SFTPClient.open`) återvänder
    // — `Task.cancel()` avbryter inte en pågående, icke-avbrytbar NIO-future.
    private var connectingChain: SSHConnectionChain?
    private var client: Client?
    private var connectingTask: Task<Client?, Never>?
    private var isTornDown = false
    // Sant om den pågående/senaste tasken redan rapporterat ett SPECIFIKT
    // fel (auth/anslutning/öppning) via `onError` — då ska inte den
    // generiska "avbröts, försök igen"-fallbacken skriva över det.
    private var raisedError = false

    private let closeClient: (Client) async -> Void

    /// `closeClient`: hur en redan öppnad klient stängs INNAN kedjan
    /// stängs, om `Client` är något annat än själva sessionen (t.ex.
    /// `SFTPClient`, som håller ett eget subsystem ovanpå kedjans target).
    /// Lämna default (no-op) när `Client` bara ÄR sessionen — då räcker
    /// det att stänga kedjan.
    init(closeClient: @escaping (Client) async -> Void = { _ in }) {
        self.closeClient = closeClient
    }

    /// Målsessionen i den aktiva kedjan, oavsett `Client`-typ — för
    /// anropsplatser (som `SFTPBrowserModel`s arkivoperationer) som behöver
    /// en `SSHSession` vid sidan av den öppnade klienten.
    var target: SSHSession? { chain?.target }

    /// Returnerar den cachade klienten om en finns, väntar in ett redan
    /// pågående försök om ett sådant är i gång, eller startar ett nytt.
    ///
    /// `connect`/`open` delar upp anslutningen i två steg av samma skäl som
    /// `SFTPBrowserModel` ursprungligen gjorde det: `open` kan vara en
    /// trivial identitet (`{ $0.target }` för Docker/PortForward) eller ett
    /// eget förhandlingssteg (`SFTPClient.open`) — bara genom att hålla
    /// isär dem kan `connectingChain` publiceras EFTER `connect()` men
    /// FÖRE `open(_:)`, vilket är precis det fönster `disconnect()` annars
    /// inte hade något att agera på under.
    func ensure(
        connect: @escaping () async throws -> SSHConnectionChain,
        open: @escaping (SSHConnectionChain) async throws -> Client,
        onError: @escaping (String) -> Void
    ) async -> Client? {
        guard !isTornDown else { return nil }
        if let client { return client }
        if let connectingTask {
            let result = await connectingTask.value
            // `disconnect()` kan ha kört FÄRDIGT medan vi väntade in NÅGON
            // ANNAN anropares `connectingTask` här — utan omkontrollen
            // skulle vi returnera en klient som redan är (eller snart blir)
            // stängd, i stället för att upptäcka teardownen.
            guard !isTornDown, let result, client === result else {
                if !isTornDown && !raisedError {
                    onError("Anslutningen avbröts, försök igen.")
                }
                return nil
            }
            return result
        }

        raisedError = false
        let task = Task<Client?, Never> { [weak self] in
            guard let self else { return nil }
            let c: SSHConnectionChain
            do {
                c = try await connect()
            } catch {
                self.raisedError = true
                onError("\(error)")
                return nil
            }
            // `disconnect()` kan ha körts medan vi väntade på `connect()`
            // ovan — utan den här kollen skulle vi återuppliva `self.chain`
            // EFTER att `disconnect()` redan städat, och den nya
            // anslutningen skulle aldrig stängas.
            guard !Task.isCancelled else {
                await c.close()
                return nil
            }
            // Synlig för disconnect() REDAN nu, se kommentaren vid fältet.
            self.connectingChain = c
            do {
                let opened = try await open(c)
                // "Claimar" kedjan (kollar OCH nollar `connectingChain` i
                // samma MainActor-tur, ingen `await` emellan) innan den
                // ev. stängs nedan — om `disconnect()` redan hunnit nolla
                // fältet och stänga `c` själv, ska VI inte stänga den igen
                // (dubbelstängning av samma `SSHConnectionChain` är inte
                // garanterat säkert).
                let stillOwnedByUs = self.connectingChain != nil
                self.connectingChain = nil
                guard !Task.isCancelled else {
                    await self.closeClient(opened)
                    if stillOwnedByUs { await c.close() }
                    return nil
                }
                self.chain = c
                self.client = opened
                return opened
            } catch {
                let stillOwnedByUs = self.connectingChain != nil
                self.connectingChain = nil
                if stillOwnedByUs { await c.close() }
                self.raisedError = true
                onError("\(error)")
                return nil
            }
        }
        connectingTask = task
        let result = await task.value
        connectingTask = nil
        // Samma race som förklaras ovan i tasken själv, men täcker fönstret
        // MELLAN att tasken kollade `Task.isCancelled` och att `await
        // task.value` returnerar här: `disconnect()` kan ha hunnit köra
        // FÄRDIGT i det fönstret utan att tasken själv märkte det.
        guard !isTornDown, let result, client === result else {
            if !isTornDown && !raisedError {
                onError("Anslutningen avbröts, försök igen.")
            }
            return nil
        }
        return result
    }

    /// En användning av den cachade sessionen misslyckades (t.ex. ett
    /// kommando kastade ett handskaknings-/kanalfel, inte bara en icke-noll
    /// exitkod) — stänger och nollar den cachade klienten/kedjan så nästa
    /// `ensure(...)` återansluter, men (till skillnad från `disconnect()`)
    /// sätter INTE `isTornDown`: anropsplatsen ska kunna återansluta.
    ///
    /// `session` måste vara ANROPETS session, inte bara "den nuvarande" —
    /// om ett sent fel kommer från en GAMMAL session efter att en ny redan
    /// hunnit koppla upp (t.ex. ett överlappande `act()`/`refresh()`) ska
    /// den nya, redan uppkopplade kedjan inte stängas.
    func invalidateIfCurrent(_ session: SSHSession) {
        guard chain?.target === session else { return }
        let c = chain
        chain = nil
        client = nil
        Task { await c?.close() }
    }

    /// Stänger klienten (om en egen stängning behövs), kedjan, och en ev.
    /// kedja som fortfarande höll på att öppnas — avbryter också ett
    /// pågående anslutningsförsök så det inte kan återuppliva en ny
    /// anslutning efter att den här metoden returnerat.
    ///
    /// `isTornDown` sätts och referenserna nollas SYNKRONT innan `before`
    /// körs — annars kunde ett samtidigt `ensure(...)`-anrop (t.ex. från en
    /// åtgärd som redan hunnit förbi den cachade klienten) hinna återansluta
    /// under fönstret medan `before` fortfarande väntar.
    ///
    /// `before`: extra städning (t.ex. att stänga beroende resurser som
    /// portvidarebefordringar) som ska köras och bli KLAR innan kedjan
    /// själv stängs — samma ordning `PortForwardModel` redan förlitade sig
    /// på (tunnlarna dirigerar trafik genom sessionen).
    func disconnect(before: @escaping () async -> Void = {}) {
        isTornDown = true
        connectingTask?.cancel()
        let c = chain
        let cc = connectingChain
        let cl = client
        chain = nil
        connectingChain = nil
        client = nil
        Task { [closeClient] in
            await before()
            if let cl { await closeClient(cl) }
            await c?.close()
            await cc?.close()
        }
    }
}
#endif
