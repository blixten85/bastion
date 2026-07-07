import Foundation
import NIOCore
import NIOPosix

/// Klient för `ssh-agent`-protokollet (`draft-miller-ssh-agent`, det OpenSSH
/// faktiskt talar över `$SSH_AUTH_SOCK`) — Agent Forwarding-grundstenen.
/// v1: lista identiteter + begära en signatur från en KÖRANDE, LOKAL agent.
/// INTE forwarding över en SSH-kanal till en fjärrserver än (`auth-agent@
/// openssh.com`-kanaltypen) — det är nästa, separata steg (kräver att
/// koppla ihop den här klientens ramning med en SSH-kanal istället för ett
/// rått Unix-socket, se ROADMAP).
///
/// Trådformatet verifierat mot `draft-miller-ssh-agent-09` (IETF), inte
/// gissat: `uint32 längd` + `byte typ` + innehåll, samma SSH-strängkodning
/// (uint32-längd-prefix) som resten av kodbasen redan använder.
public struct SSHAgentIdentity: Sendable, Equatable {
    public let keyBlob: Data
    public let comment: String
}

public enum SSHAgentError: Error, Sendable {
    case connectionFailed(String)
    case protocolViolation(String)
    case agentFailure
}

private enum SSHAgentMessageType: UInt8 {
    case failure = 5
    case success = 6
    case requestIdentities = 11
    case identitiesAnswer = 12
    case signRequest = 13
    case signResponse = 14
}

/// Ramar inkommande bytes (`uint32`-längdprefix) till hela meddelanden och
/// matar dem till en `AsyncStream` — samma NIO-callback  ->  async-ström-
/// idiom som `SFTPBridgeHandler`/`execute()` redan använder i den här kodbasen.
private final class SSHAgentFramingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var buffer = ByteBuffer()
    private let continuation: AsyncStream<ByteBuffer>.Continuation

    init(continuation: AsyncStream<ByteBuffer>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while true {
            guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else { break }
            guard buffer.readableBytes >= 4 + Int(length) else { break }
            _ = buffer.readInteger(as: UInt32.self)
            guard let message = buffer.readSlice(length: Int(length)) else { break }
            continuation.yield(message)
        }
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

public actor SSHAgentClient {
    private let channel: Channel
    private var messages: AsyncStream<ByteBuffer>.Iterator

    private init(channel: Channel, stream: AsyncStream<ByteBuffer>) {
        self.channel = channel
        self.messages = stream.makeAsyncIterator()
    }

    /// Ansluter till en körande agents Unix-socket (typiskt `$SSH_AUTH_SOCK`).
    public static func connect(socketPath: String, group: EventLoopGroup) async throws -> SSHAgentClient {
        var streamContinuation: AsyncStream<ByteBuffer>.Continuation!
        let stream = AsyncStream<ByteBuffer> { streamContinuation = $0 }
        let continuation = streamContinuation!

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SSHAgentFramingHandler(continuation: continuation))
                }
            }
        do {
            let channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()
            return SSHAgentClient(channel: channel, stream: stream)
        } catch {
            throw SSHAgentError.connectionFailed(String(describing: error))
        }
    }

    private func nextRawMessage() async -> ByteBuffer? {
        // `next()` är en muterande async-metod — kan inte anropas direkt på
        // en actor-isolerad lagrad egenskap (Swift kan inte bevisa exklusiv
        // åtkomst över en suspensionspunkt). Kopiera ut, mutera lokalt,
        // skriv tillbaka.
        var iterator = messages
        let result = await iterator.next()
        messages = iterator
        return result
    }

    private func send(type: SSHAgentMessageType, body: (inout ByteBuffer) -> Void) async throws -> ByteBuffer {
        var payload = channel.allocator.buffer(capacity: 64)
        payload.writeInteger(type.rawValue)
        body(&payload)
        var framed = channel.allocator.buffer(capacity: payload.readableBytes + 4)
        framed.writeInteger(UInt32(payload.readableBytes))
        framed.writeBuffer(&payload)
        channel.writeAndFlush(framed, promise: nil)

        guard let response = await nextRawMessage() else {
            throw SSHAgentError.connectionFailed("agenten stängde anslutningen")
        }
        return response
    }

    /// Listar de identiteter (publika nycklar) agenten för närvarande har laddade.
    public func requestIdentities() async throws -> [SSHAgentIdentity] {
        var response = try await send(type: .requestIdentities) { _ in }
        guard let rawType: UInt8 = response.readInteger(),
              let type = SSHAgentMessageType(rawValue: rawType)
        else {
            throw SSHAgentError.protocolViolation("okänt svar")
        }
        guard type == .identitiesAnswer else {
            if type == .failure { throw SSHAgentError.agentFailure }
            throw SSHAgentError.protocolViolation("väntade IDENTITIES_ANSWER, fick \(type)")
        }
        guard let count: UInt32 = response.readInteger() else {
            throw SSHAgentError.protocolViolation("trunkerat IDENTITIES_ANSWER")
        }
        var identities: [SSHAgentIdentity] = []
        for _ in 0..<count {
            guard let blob = response.readSSHString(), let comment = response.readSSHString() else {
                throw SSHAgentError.protocolViolation("trunkerad identitet")
            }
            identities.append(SSHAgentIdentity(keyBlob: Data(blob), comment: String(decoding: comment, as: UTF8.self)))
        }
        return identities
    }

    /// Ber agenten signera `data` med den privata nyckel som hör till
    /// `keyBlob` (måste matcha en av `requestIdentities()`s poster — agenten
    /// signerar bara med nycklar den själv har laddat, aldrig med en nyckel
    /// vi skickar in). Returnerar den råa signaturblobben
    /// (`string keytype + string signature`, enligt RFC8709 för Ed25519).
    public func sign(keyBlob: Data, data: Data, flags: UInt32 = 0) async throws -> Data {
        var response = try await send(type: .signRequest) { buf in
            buf.writeSSHString(Array(keyBlob))
            buf.writeSSHString(Array(data))
            buf.writeInteger(flags)
        }
        guard let rawType: UInt8 = response.readInteger(),
              let type = SSHAgentMessageType(rawValue: rawType)
        else {
            throw SSHAgentError.protocolViolation("okänt svar")
        }
        guard type == .signResponse else {
            if type == .failure { throw SSHAgentError.agentFailure }
            throw SSHAgentError.protocolViolation("väntade SIGN_RESPONSE, fick \(type)")
        }
        guard let signature = response.readSSHString() else {
            throw SSHAgentError.protocolViolation("trunkerat SIGN_RESPONSE")
        }
        return Data(signature)
    }

    public func close() async {
        try? await channel.close().get()
    }
}

private extension ByteBuffer {
    mutating func readSSHString() -> [UInt8]? {
        guard let length: UInt32 = readInteger() else { return nil }
        return readBytes(length: Int(length))
    }

    mutating func writeSSHString(_ bytes: [UInt8]) {
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }
}
