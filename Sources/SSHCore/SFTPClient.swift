import NIOCore
import NIOSSH

/// Vidarebefordrar rå `ByteBuffer`-bitar från SSH-barnkanalen (efter
/// `DirectTCPIPWrapperHandler` slagit om SSHChannelData -> ByteBuffer) till en
/// `AsyncStream` som `SFTPClient`-aktören konsumerar. Ren I/O-brygga, ingen
/// SFTP-protokollogik här — samma idiom som `execute()`/`openShell()` redan
/// använder (NIO-callbacks -> AsyncThrowingStream/AsyncStream).
final class SFTPBridgeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<ByteBuffer>.Continuation

    init(continuation: AsyncStream<ByteBuffer>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.fireErrorCaught(error)
    }
}

public struct SFTPFileHandle: Sendable {
    let handle: [UInt8]
}

public enum SFTPClientError: Error, Sendable, Equatable {
    case channelClosed
    case unsupportedVersion(UInt32)
    case protocolViolation(String)
}

/// SFTP-klient (version 3, det OpenSSH faktiskt talar) ovanpå en `SSHSession`.
/// Öppnar en egen "sftp"-subsystem-barnkanal, gör INIT/VERSION-handskakningen,
/// och matchar sedan svar mot förfrågningar via SFTP:s eget id-fält — flera
/// samtidiga förfrågningar över samma kanal är därför säkert (aktören
/// serialiserar åtkomsten till `pending`-tabellen).
public actor SFTPClient {
    private let channel: Channel
    private var nextRequestID: UInt32 = 0
    private var pending: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var versionContinuation: CheckedContinuation<SFTPResponse, Error>?
    private var readBuffer = ByteBuffer()
    private var pumpTask: Task<Void, Never>?

    private init(channel: Channel) {
        self.channel = channel
    }

    /// Registrerar öppningen som en "barn-operation" på sessionen (samma
    /// mekanism som `execute()`/`openShell()` redan använder internt) —
    /// annars kan `session.close()` hinna köra `group.shutdownGracefully()`
    /// medan `createChannel`-promisen nedan fortfarande är olöst, vilket
    /// kraschar processen (NIOs "leaking promise"-detektor, samma
    /// sårbarhetsklass som grundorsaksfixades för execute()/openShell() i
    /// PR #183 — `SFTPClient.open` gick via en fristående funktion utanför
    /// `SSHSession` och fick aldrig samma skydd). `beginChildOp()` kastar
    /// direkt om sessionen redan håller på att stängas, och `close()`s
    /// `waitForChildOpsToDrain()` väntar nu automatiskt in den här öppningen
    /// innan den river event loop-gruppen.
    public static func open(on session: SSHSession) async throws -> SFTPClient {
        try session.beginChildOp()
        do {
            let client = try await openChildChannel(on: session)
            session.endChildOp()
            return client
        } catch {
            session.endChildOp()
            throw error
        }
    }

    private static func openChildChannel(on session: SSHSession) async throws -> SFTPClient {
        guard let channel = session.channel else {
            throw SSHError.channelFailed("inte ansluten")
        }
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }

        var streamContinuation: AsyncStream<ByteBuffer>.Continuation!
        let stream = AsyncStream<ByteBuffer> { streamContinuation = $0 }
        let bridgeContinuation = streamContinuation!

        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(childPromise, channelType: .session) { child, _ in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(DirectTCPIPWrapperHandler())
                try child.pipeline.syncOperations.addHandler(SFTPBridgeHandler(continuation: bridgeContinuation))
            }
        }
        let child: Channel
        do {
            child = try await childPromise.futureResult.get()
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }

        do {
            let subsystem = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
            try await child.triggerUserOutboundEvent(subsystem)
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }

        let client = SFTPClient(channel: child)
        await client.startPump(stream)
        try await client.performHandshake()
        return client
    }

    private func startPump(_ stream: AsyncStream<ByteBuffer>) {
        pumpTask = Task { [weak self] in
            for await chunk in stream {
                await self?.feed(chunk)
            }
            await self?.failAllPending(SFTPClientError.channelClosed)
        }
    }

    // MARK: - Ramning + utskick (körs isolerat på aktören)

    private func feed(_ chunk: ByteBuffer) {
        var incoming = chunk
        readBuffer.writeBuffer(&incoming)
        while true {
            guard let length: UInt32 = readBuffer.getInteger(at: readBuffer.readerIndex) else { break }
            guard readBuffer.readableBytes >= 4 + Int(length) else { break }
            _ = readBuffer.readInteger(as: UInt32.self)
            guard var payload = readBuffer.readSlice(length: Int(length)) else { break }
            dispatch(&payload)
        }
    }

    private func dispatch(_ payload: inout ByteBuffer) {
        guard let rawType: UInt8 = payload.readInteger(), let type = SFTPMessageType(rawValue: rawType),
              let response = try? SFTPResponse.decode(type: type, from: &payload)
        else {
            // Ett paket vi inte kan tolka betyder att strömmen är ur synk —
            // det finns inget säkert sätt att veta vilket pending-id det
            // SKULLE ha matchat. Utan detta skulle den väntande continuation
            // hänga för evigt (CodeRabbit-fynd, PR #38).
            failAllPending(SFTPClientError.protocolViolation("kunde inte avkoda serversvar"))
            return
        }

        if case .version = response {
            versionContinuation?.resume(returning: response)
            versionContinuation = nil
            return
        }
        let id: UInt32
        switch response {
        case .version: return  // ovanför, oåtkomlig gren
        case .status(let rid, _, _), .handle(let rid, _), .data(let rid, _),
             .name(let rid, _), .attrs(let rid, _):
            id = rid
        }
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(returning: response)
        }
    }

    private func failAllPending(_ error: Error) {
        versionContinuation?.resume(throwing: error)
        versionContinuation = nil
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }

    private func nextID() -> UInt32 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func request(_ packet: ByteBuffer, id: UInt32) async throws -> SFTPResponse {
        try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            channel.writeAndFlush(packet, promise: nil)
        }
    }

    private func performHandshake() async throws {
        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFTPResponse, Error>) in
            versionContinuation = cont
            channel.writeAndFlush(SFTPRequest.initMessage(version: 3), promise: nil)
        }
        guard case .version(let serverVersion) = response else {
            throw SFTPClientError.protocolViolation("väntade VERSION, fick något annat")
        }
        guard serverVersion == 3 else {
            throw SFTPClientError.unsupportedVersion(serverVersion)
        }
    }

    // MARK: - Katalog

    public func realpath(_ path: String) async throws -> String {
        let id = nextID()
        let response = try await request(SFTPRequest.realpath(id: id, path: path), id: id)
        switch response {
        case .name(_, let entries):
            guard let first = entries.first else {
                throw SFTPClientError.protocolViolation("realpath: tomt NAME-svar")
            }
            return first.filename
        case .status(_, let code, let message):
            throw SFTPStatusError(code: code, message: message)
        default:
            throw SFTPClientError.protocolViolation("oväntat svar på realpath")
        }
    }

    public func listDirectory(_ path: String) async throws -> [SFTPNameEntry] {
        let openID = nextID()
        let openResponse = try await request(SFTPRequest.opendir(id: openID, path: path), id: openID)
        let handle: [UInt8]
        switch openResponse {
        case .handle(_, let h): handle = h
        case .status(_, let code, let message): throw SFTPStatusError(code: code, message: message)
        default: throw SFTPClientError.protocolViolation("oväntat svar på opendir")
        }

        var entries: [SFTPNameEntry] = []
        do {
            readLoop: while true {
                let readID = nextID()
                let readResponse = try await request(SFTPRequest.readdir(id: readID, handle: handle), id: readID)
                switch readResponse {
                case .name(_, let batch):
                    entries.append(contentsOf: batch)
                case .status(_, .eof, _):
                    break readLoop
                case .status(_, let code, let message):
                    throw SFTPStatusError(code: code, message: message)
                default:
                    throw SFTPClientError.protocolViolation("oväntat svar på readdir")
                }
            }
        } catch {
            // Stäng handtaget även när loopen kastar — annars läcker det på
            // serversidan för resten av kanalens livstid (CodeRabbit-fynd).
            await closeHandleBestEffort(handle)
            throw error
        }

        try await closeFileHandle(handle)
        return entries
    }

    /// Stänger ett SFTP-handtag utan att kasta — används i felvägar där vi
    /// redan är på väg att kasta det ursprungliga felet och inte vill dölja
    /// det bakom ett sekundärt close-fel.
    private func closeHandleBestEffort(_ handle: [UInt8]) async {
        let id = nextID()
        _ = try? await request(SFTPRequest.close(id: id, handle: handle), id: id)
    }

    private func closeFileHandle(_ handle: [UInt8]) async throws {
        let id = nextID()
        _ = try await request(SFTPRequest.close(id: id, handle: handle), id: id)
    }

    public func mkdir(_ path: String) async throws {
        let id = nextID()
        let response = try await request(SFTPRequest.mkdir(id: id, path: path), id: id)
        try Self.expectOK(response)
    }

    public func rmdir(_ path: String) async throws {
        let id = nextID()
        let response = try await request(SFTPRequest.rmdir(id: id, path: path), id: id)
        try Self.expectOK(response)
    }

    public func remove(_ path: String) async throws {
        let id = nextID()
        let response = try await request(SFTPRequest.remove(id: id, path: path), id: id)
        try Self.expectOK(response)
    }

    public func rename(_ oldPath: String, to newPath: String) async throws {
        let id = nextID()
        let response = try await request(SFTPRequest.rename(id: id, oldPath: oldPath, newPath: newPath), id: id)
        try Self.expectOK(response)
    }

    /// `mode`: POSIX-behörighetsbitar, t.ex. `0o644` eller `0o755` — samma
    /// format som `chmod`. Ändrar bara behörigheter, rör inte ägare/grupp
    /// (se `chown(_:uid:gid:)` för det).
    public func setPermissions(_ path: String, mode: UInt32) async throws {
        let id = nextID()
        let response = try await request(
            SFTPRequest.setstat(id: id, path: path, attributes: SFTPFileAttributes(permissions: mode)), id: id)
        try Self.expectOK(response)
    }

    /// Byter ägare/grupp — `chown`. SFTP version 3 har inget separat
    /// "chown"-kommando, bara UID/GID i samma SETSTAT-anrop som permissions,
    /// och kräver NUMERISKA ID:n (inte användarnamn — servern översätter
    /// aldrig "alice" till en UID åt oss). Anroparen ansvarar för att slå
    /// upp rätt UID/GID (t.ex. via `id -u alice`/`id -g alice` över ett
    /// separat exec-kommando) innan den här anropas.
    public func chown(_ path: String, uid: UInt32, gid: UInt32) async throws {
        let id = nextID()
        let response = try await request(
            SFTPRequest.setstat(id: id, path: path, attributes: SFTPFileAttributes(uid: uid, gid: gid)), id: id)
        try Self.expectOK(response)
    }

    public func stat(_ path: String) async throws -> SFTPFileAttributes {
        let id = nextID()
        let response = try await request(SFTPRequest.stat(id: id, path: path), id: id)
        switch response {
        case .attrs(_, let attrs): return attrs
        case .status(_, let code, let message): throw SFTPStatusError(code: code, message: message)
        default: throw SFTPClientError.protocolViolation("oväntat svar på stat")
        }
    }

    // MARK: - Filer

    public func openFile(_ path: String, flags: SFTPOpenFlags) async throws -> SFTPFileHandle {
        let id = nextID()
        let response = try await request(SFTPRequest.open(id: id, path: path, flags: flags), id: id)
        switch response {
        case .handle(_, let handle): return SFTPFileHandle(handle: handle)
        case .status(_, let code, let message): throw SFTPStatusError(code: code, message: message)
        default: throw SFTPClientError.protocolViolation("oväntat svar på open")
        }
    }

    /// `nil` = EOF nådd.
    public func read(_ handle: SFTPFileHandle, offset: UInt64, length: UInt32) async throws -> [UInt8]? {
        let id = nextID()
        let response = try await request(
            SFTPRequest.read(id: id, handle: handle.handle, offset: offset, length: length), id: id)
        switch response {
        case .data(_, let bytes): return bytes
        case .status(_, .eof, _): return nil
        case .status(_, let code, let message): throw SFTPStatusError(code: code, message: message)
        default: throw SFTPClientError.protocolViolation("oväntat svar på read")
        }
    }

    public func write(_ handle: SFTPFileHandle, offset: UInt64, data: [UInt8]) async throws {
        let id = nextID()
        let response = try await request(
            SFTPRequest.write(id: id, handle: handle.handle, offset: offset, data: data), id: id)
        try Self.expectOK(response)
    }

    public func closeFile(_ handle: SFTPFileHandle) async throws {
        let id = nextID()
        let response = try await request(SFTPRequest.close(id: id, handle: handle.handle), id: id)
        try Self.expectOK(response)
    }

    /// Läser en hel fil i bitar av `chunkSize` (32 KiB som standard).
    public func readFile(_ path: String, chunkSize: UInt32 = 32768) async throws -> [UInt8] {
        // chunkSize: 0 skulle aldrig avancera (read() med length: 0 hänger
        // eller loopar för evigt beroende på serverns svar) — CodeRabbit-fynd.
        guard chunkSize > 0 else {
            throw SFTPClientError.protocolViolation("chunkSize måste vara större än 0")
        }
        let handle = try await openFile(path, flags: .read)
        var result: [UInt8] = []
        var offset: UInt64 = 0
        do {
            while let chunk = try await read(handle, offset: offset, length: chunkSize) {
                result.append(contentsOf: chunk)
                offset += UInt64(chunk.count)
                if chunk.isEmpty { break }  // undviker oändlig loop mot en server som svarar tom DATA i stället för EOF
            }
        } catch {
            try? await closeFile(handle)
            throw error
        }
        try await closeFile(handle)
        return result
    }

    /// Skriver en hel fil i bitar (skapar/trunkerar).
    public func writeFile(_ path: String, data: [UInt8], chunkSize: Int = 32768) async throws {
        // chunkSize <= 0: prefix(0)/dropFirst(0) avancerar aldrig -> oändlig
        // loop (CodeRabbit-fynd). Negativa värden kan dessutom trappa i
        // ArraySlice.prefix(_:).
        guard chunkSize > 0 else {
            throw SFTPClientError.protocolViolation("chunkSize måste vara större än 0")
        }
        let handle = try await openFile(path, flags: [.write, .create, .truncate])
        var offset: UInt64 = 0
        var remaining = data[...]
        do {
            while !remaining.isEmpty {
                let chunk = Array(remaining.prefix(chunkSize))
                try await write(handle, offset: offset, data: chunk)
                offset += UInt64(chunk.count)
                remaining = remaining.dropFirst(chunk.count)
            }
        } catch {
            try? await closeFile(handle)
            throw error
        }
        try await closeFile(handle)
    }

    private static func expectOK(_ response: SFTPResponse) throws {
        guard case .status(_, let code, let message) = response else {
            throw SFTPClientError.protocolViolation("väntade STATUS, fick något annat")
        }
        guard code == .ok else {
            throw SFTPStatusError(code: code, message: message)
        }
    }

    public func close() async {
        pumpTask?.cancel()
        try? await channel.close().get()
    }
}
