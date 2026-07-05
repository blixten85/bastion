import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
@testable import SSHCore

// En minimal SSH-server i processen, enbart för test. Accepterar ett lösenord
// och svarar på exec-förfrågningar med "ran: <kommando>\n" + exit 0.

final class ServerAuth: NIOSSHServerUserAuthenticationDelegate {
    let password: String
    init(password: String) { self.password = password }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        [.password, .publicKey]
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .password(let p):
            responsePromise.succeed(p.password == password ? .success : .failure)
        case .publicKey:
            // NIOSSH har redan verifierat signaturen; testservern godtar nyckeln.
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

final class ServerExecHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private var shellMode = false
    private let sftpRoot: String

    init(sftpRoot: String) {
        self.sftpRoot = sftpRoot
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exec = event as? SSHChannelRequestEvent.ExecRequest {
            var buf = context.channel.allocator.buffer(capacity: 32)
            buf.writeString("ran: \(exec.command)\n")
            let data = SSHChannelData(type: .channel, data: .byteBuffer(buf))
            context.writeAndFlush(wrapOutboundOut(data), promise: nil)
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
            context.close(promise: nil)
        } else if event is SSHChannelRequestEvent.ShellRequest {
            // Enkel "echo-shell": speglar all stdin tillbaka som stdout.
            shellMode = true
        } else if let subsystem = event as? SSHChannelRequestEvent.SubsystemRequest, subsystem.subsystem == "sftp" {
            // Byter ut sig själv mot en dedikerad SFTP-handler för resten av
            // kanalens livstid — samma mönster som protokolluppgraderingar
            // (t.ex. HTTP -> WebSocket) i övriga NIO-ekosystemet.
            _ = context.pipeline.removeHandler(self)
            _ = context.pipeline.addHandler(ServerSFTPHandler(rootPath: sftpRoot))
        }
        // PseudoTerminalRequest ignoreras (accepteras implicit).
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard shellMode else { return }
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer = channelData.data else { return }
        context.writeAndFlush(wrapOutboundOut(channelData), promise: nil)
    }
}

/// Minimal SFTP-server (version 3) för test — backad av ett riktigt
/// temp-directory (verklig filsystemsemantik: `FileManager`/`FileHandle`),
/// inte bara ett protokolleko. Räcker för att verifiera `SFTPClient`s
/// kanaltrådning/ramning/id-matchning på riktigt, utan att bero på ett
/// riktigt `sftp-server`-underprocess (fragilt att brygga ihop med
/// NIOPipeBootstrap + Foundation.Process — ett eget, separat steg om det
/// någonsin behövs för djupare protokollkompatibilitetsverifiering).
final class ServerSFTPHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private enum Handle {
        case directory(remaining: [String])
        case file(FileHandle)
    }

    private let rootPath: String
    private var inbound = ByteBuffer()
    private var handles: [UInt64: Handle] = [:]
    private var nextHandleID: UInt64 = 0

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// Håller sökvägar innanför `rootPath` — utan detta kunde en `../`
    /// eller absolut sökväg fly sandlådan och mutera godtyckliga filer
    /// testprocessen har åtkomst till (CodeRabbit-fynd, PR #38). En
    /// icke-existerande sökväg (`__blocked__`) gör att alla efterföljande
    /// filsystemsanrop svarar "hittades inte" på ett säkert sätt, utan att
    /// göra den här (icke-kastande) funktionen throwing.
    private func diskPath(for sftpPath: String) -> String {
        let trimmed = sftpPath.hasPrefix("/") ? String(sftpPath.dropFirst()) : sftpPath
        let candidate = trimmed.isEmpty || trimmed == "." ? rootPath : rootPath + "/" + trimmed
        let standardized = (candidate as NSString).standardizingPath
        guard standardized == rootPath || standardized.hasPrefix(rootPath + "/") else {
            return rootPath + "/__blocked_path_traversal__"
        }
        return standardized
    }

    private func allocateHandle(_ handle: Handle) -> [UInt8] {
        let id = nextHandleID
        nextHandleID += 1
        handles[id] = handle
        return withUnsafeBytes(of: id.bigEndian, Array.init)
    }

    /// Bygger UInt64 byte-för-byte istället för `withUnsafeBytes { $0.load(as:) }`
    /// — den senare kan trappa på en `[UInt8]` vars underliggande lagring
    /// inte råkar vara 8-byte-alignad (CodeRabbit-fynd, PR #38).
    private func handleID(from bytes: [UInt8]) -> UInt64? {
        guard bytes.count == 8 else { return nil }
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        return value
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var incoming) = channelData.data else { return }
        inbound.writeBuffer(&incoming)
        while true {
            guard let length: UInt32 = inbound.getInteger(at: inbound.readerIndex) else { break }
            guard inbound.readableBytes >= 4 + Int(length) else { break }
            _ = inbound.readInteger(as: UInt32.self)
            guard var payload = inbound.readSlice(length: Int(length)) else { break }
            process(&payload, context: context)
        }
    }

    private func send(_ packet: ByteBuffer, context: ChannelHandlerContext) {
        let data = SSHChannelData(type: .channel, data: .byteBuffer(packet))
        context.writeAndFlush(wrapOutboundOut(data), promise: nil)
    }

    private func sendStatus(id: UInt32, code: SFTPStatusCode, message: String = "", context: ChannelHandlerContext) {
        let packet = makeSFTPPacket(type: .status) { buf in
            buf.writeInteger(id)
            buf.writeInteger(code.rawValue)
            buf.writeSFTPString(message)
            buf.writeSFTPString("")
        }
        send(packet, context: context)
    }

    private func sendHandle(id: UInt32, handle: [UInt8], context: ChannelHandlerContext) {
        let packet = makeSFTPPacket(type: .handle) { buf in
            buf.writeInteger(id)
            buf.writeSFTPBytes(handle)
        }
        send(packet, context: context)
    }

    private func attributes(atDiskPath path: String) -> SFTPFileAttributes {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return SFTPFileAttributes() }
        let size = (attrs[.size] as? NSNumber)?.uint64Value
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let posixBits = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? (isDir ? 0o755 : 0o644)
        // Riktiga SFTP-servrar lägger filtypen (S_IFDIR/S_IFREG) i samma
        // permissions-fält, inte bara de nio låga behörighetsbitarna —
        // annars kan en klient inte skilja mapp från fil utan ett extra
        // STAT-anrop per post.
        let typeBits: UInt32 = isDir ? 0o040000 : 0o100000
        return SFTPFileAttributes(size: size, permissions: posixBits | typeBits)
    }

    private func process(_ payload: inout ByteBuffer, context: ChannelHandlerContext) {
        guard let rawType: UInt8 = payload.readInteger(), let type = SFTPMessageType(rawValue: rawType) else { return }
        let fm = FileManager.default

        switch type {
        case .initMsg:
            _ = payload.readInteger(as: UInt32.self)
            send(makeSFTPPacket(type: .version) { $0.writeInteger(UInt32(3)) }, context: context)

        case .realpath:
            guard let id: UInt32 = payload.readInteger(), let path = try? payload.readSFTPString() else { return }
            let resolved = path.hasPrefix("/") ? path : "/" + path
            let packet = makeSFTPPacket(type: .name) { buf in
                buf.writeInteger(id)
                buf.writeInteger(UInt32(1))
                buf.writeSFTPString(resolved)
                buf.writeSFTPString(resolved)
                SFTPFileAttributes().encode(into: &buf)
            }
            send(packet, context: context)

        case .opendir:
            guard let id: UInt32 = payload.readInteger(), let path = try? payload.readSFTPString() else { return }
            let disk = diskPath(for: path)
            guard let entries = try? fm.contentsOfDirectory(atPath: disk) else {
                sendStatus(id: id, code: .noSuchFile, message: "no such directory", context: context)
                return
            }
            let handle = allocateHandle(.directory(remaining: entries))
            sendHandle(id: id, handle: handle, context: context)

        case .readdir:
            // id läses ut separat FÖRST så en ogiltig handle-referens ändå
            // kan besvaras med rätt id — annars väntar klienten på den
            // pending-continuationen för evigt (CodeRabbit-fynd, PR #38).
            guard let id: UInt32 = payload.readInteger() else { return }
            guard let handleBytes = try? payload.readSFTPBytes(),
                  let hid = handleID(from: handleBytes), case .directory(let remaining) = handles[hid]
            else {
                sendStatus(id: id, code: .failure, context: context)
                return
            }
            guard !remaining.isEmpty else {
                sendStatus(id: id, code: .eof, context: context)
                return
            }
            let batch = remaining
            handles[hid] = .directory(remaining: [])
            let packet = makeSFTPPacket(type: .name) { buf in
                buf.writeInteger(id)
                buf.writeInteger(UInt32(batch.count))
                for name in batch {
                    buf.writeSFTPString(name)
                    buf.writeSFTPString(name)
                    attributes(atDiskPath: rootPath + "/" + name).encode(into: &buf)
                }
            }
            send(packet, context: context)

        case .close:
            guard let id: UInt32 = payload.readInteger() else { return }
            guard let handleBytes = try? payload.readSFTPBytes(), let hid = handleID(from: handleBytes)
            else {
                sendStatus(id: id, code: .failure, context: context)
                return
            }
            if case .file(let fh) = handles[hid] { try? fh.close() }
            handles.removeValue(forKey: hid)
            sendStatus(id: id, code: .ok, context: context)

        case .open:
            guard let id: UInt32 = payload.readInteger(), let path = try? payload.readSFTPString(),
                  let flags: UInt32 = payload.readInteger()
            else { return }
            _ = try? SFTPFileAttributes.decode(from: &payload)
            let disk = diskPath(for: path)
            let openFlags = SFTPOpenFlags(rawValue: flags)
            if openFlags.contains(.create) && !fm.fileExists(atPath: disk) {
                _ = fm.createFile(atPath: disk, contents: nil)
            }
            guard fm.fileExists(atPath: disk) else {
                sendStatus(id: id, code: .noSuchFile, context: context)
                return
            }
            if openFlags.contains(.truncate) {
                try? Data().write(to: URL(fileURLWithPath: disk))
            }
            let fh = openFlags.contains(.write)
                ? FileHandle(forUpdatingAtPath: disk) : FileHandle(forReadingAtPath: disk)
            guard let fh else {
                sendStatus(id: id, code: .permissionDenied, context: context)
                return
            }
            let handle = allocateHandle(.file(fh))
            sendHandle(id: id, handle: handle, context: context)

        case .read:
            guard let id: UInt32 = payload.readInteger() else { return }
            guard let handleBytes = try? payload.readSFTPBytes(),
                  let hid = handleID(from: handleBytes), let offset: UInt64 = payload.readInteger(),
                  let length: UInt32 = payload.readInteger(), case .file(let fh) = handles[hid]
            else {
                sendStatus(id: id, code: .failure, context: context)
                return
            }
            try? fh.seek(toOffset: offset)
            let data = (try? fh.read(upToCount: Int(length))) ?? nil
            guard let data, !data.isEmpty else {
                sendStatus(id: id, code: .eof, context: context)
                return
            }
            let packet = makeSFTPPacket(type: .data) { buf in
                buf.writeInteger(id)
                buf.writeSFTPBytes(Array(data))
            }
            send(packet, context: context)

        case .write:
            guard let id: UInt32 = payload.readInteger() else { return }
            guard let handleBytes = try? payload.readSFTPBytes(),
                  let hid = handleID(from: handleBytes), let offset: UInt64 = payload.readInteger(),
                  let bytes = try? payload.readSFTPBytes(), case .file(let fh) = handles[hid]
            else {
                sendStatus(id: id, code: .failure, context: context)
                return
            }
            try? fh.seek(toOffset: offset)
            try? fh.write(contentsOf: Data(bytes))
            sendStatus(id: id, code: .ok, context: context)

        case .stat, .lstat:
            guard let id: UInt32 = payload.readInteger(), let path = try? payload.readSFTPString() else { return }
            let disk = diskPath(for: path)
            guard fm.fileExists(atPath: disk) else {
                sendStatus(id: id, code: .noSuchFile, context: context)
                return
            }
            let packet = makeSFTPPacket(type: .attrs) { buf in
                buf.writeInteger(id)
                attributes(atDiskPath: disk).encode(into: &buf)
            }
            send(packet, context: context)

        case .mkdir:
            guard let id: UInt32 = payload.readInteger(), let path = try? payload.readSFTPString() else { return }
            do {
                try fm.createDirectory(atPath: diskPath(for: path), withIntermediateDirectories: false)
                sendStatus(id: id, code: .ok, context: context)
            } catch {
                sendStatus(id: id, code: .failure, message: "\(error)", context: context)
            }

        case .rmdir, .remove:
            guard let id: UInt32 = payload.readInteger(), let path = try? payload.readSFTPString() else { return }
            do {
                try fm.removeItem(atPath: diskPath(for: path))
                sendStatus(id: id, code: .ok, context: context)
            } catch {
                sendStatus(id: id, code: .noSuchFile, message: "\(error)", context: context)
            }

        case .rename:
            guard let id: UInt32 = payload.readInteger(), let oldPath = try? payload.readSFTPString(),
                  let newPath = try? payload.readSFTPString()
            else { return }
            do {
                try fm.moveItem(atPath: diskPath(for: oldPath), toPath: diskPath(for: newPath))
                sendStatus(id: id, code: .ok, context: context)
            } catch {
                sendStatus(id: id, code: .failure, message: "\(error)", context: context)
            }

        case .setstat, .fsetstat, .fstat:
            guard let id: UInt32 = payload.readInteger() else { return }
            sendStatus(id: id, code: .opUnsupported, context: context)

        case .version, .status, .handle, .data, .name, .attrs:
            break  // svarstyper — kommer aldrig från en klient
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        for case .file(let fh) in handles.values { try? fh.close() }
        handles.removeAll()
        context.fireChannelInactive()
    }
}

/// Server-sidans direct-tcpip-handler för test: ekar bara tillbaka precis vad
/// den tar emot, oavsett vilken targetHost/targetPort klienten bad om. Räcker
/// för att bevisa hela portvidarebefordrings-vägen (lokal TCP -> SSH-kanal ->
/// tillbaka) utan att behöva ett riktigt nätverksmål.
final class ServerDirectTCPIPEchoHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

struct LoopbackServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    /// Eget temp-directory per server-instans — SFTP-testerna läser/skriver
    /// riktiga filer här, aldrig i den delade systemtemp-mappen direkt.
    let sftpRoot: String
    var port: Int { channel.localAddress?.port ?? 0 }

    static func start(password: String) throws -> LoopbackServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let sftpRoot = NSTemporaryDirectory() + "bastion-sftp-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: sftpRoot, withIntermediateDirectories: true)
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    NIOSSHHandler(
                        role: .server(.init(
                            hostKeys: [hostKey],
                            userAuthDelegate: ServerAuth(password: password))),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, channelType in
                            switch channelType {
                            case .directTCPIP:
                                return child.pipeline.addHandler(ServerDirectTCPIPEchoHandler())
                            default:
                                return child.pipeline.addHandler(ServerExecHandler(sftpRoot: sftpRoot))
                            }
                        }))
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        return LoopbackServer(group: group, channel: channel, sftpRoot: sftpRoot)
    }

    func shutdown() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
        try? FileManager.default.removeItem(atPath: sftpRoot)
    }
}
