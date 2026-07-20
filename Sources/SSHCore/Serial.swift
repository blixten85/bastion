#if os(macOS) || os(Linux)
import NIOCore
import NIOPosix
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// `close(_:)` (libc) skuggas annars av `SerialSession.close()` (instans-
// metoden med samma namn, samma publika kontrakt som `TelnetSession`/
// `SSHShell`) inuti typens egna statiska metoder — Swift löser ett obundet
// `close(fd)`-anrop där till den instansmetoden istället för libc-funktionen.
// Ett eget, otvetydigt namn löser skuggningen utan att döpa om den publika
// `close() async`-metoden.
private func closeFileDescriptor(_ fd: Int32) {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

/// Seriell/USB-anslutning (t.ex. `/dev/cu.usbserial-*` på macOS,
/// `/dev/ttyUSB*`/`/dev/ttyACM*` på Linux) — Termius har detta, Bastion
/// saknade det helt (gap-listepost #8 i
/// [[project-bastion-termius-parity-mandate]]). Mest relevant för hemmalabb/
/// nätverksutrustnings-konsolportar, därför bara macOS/Linux — iOS saknar
/// meningsfull USB-serial-åtkomst utan ett dedikerat MFi/External Accessory-
/// arbete (helt annan integration), och Windows har en helt annan
/// seriell-API (`SetCommState`, inte POSIX-termios) som denna första
/// implementation medvetet inte täcker.
public struct SerialConfig: Sendable {
    public var path: String
    public var baudRate: UInt32
    public init(path: String, baudRate: UInt32 = 9600) {
        self.path = path
        self.baudRate = baudRate
    }
}

public enum SerialError: Error, Sendable, Equatable {
    case openFailed(String)
    case configurationFailed(String)
    case unsupportedBaudRate(UInt32)
}

/// En seriell anslutning. Motsvarar `TelnetSession`s gränssnitt (`output`/
/// `send`/`close`) — rå byte-ström, inget SSH/Telnet-protokoll ovanpå. Byggd
/// på `NIOPipeBootstrap` (samma NIO-lager som TCP-kanalerna, bara ovanpå en
/// redan öppnad/konfigurerad filbeskrivare istället för ett uttag) så att
/// samma asynkrona läs-/skrivmönster återanvänds rakt av.
public final class SerialSession {
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup
    public let output: AsyncThrowingStream<[UInt8], Error>

    private init(channel: Channel, group: MultiThreadedEventLoopGroup, output: AsyncThrowingStream<[UInt8], Error>) {
        self.channel = channel
        self.group = group
        self.output = output
    }

    public static func connect(config: SerialConfig) async throws -> SerialSession {
        let fd = config.path.withCString { open($0, O_RDWR | O_NOCTTY) }
        guard fd >= 0 else {
            throw SerialError.openFailed(config.path)
        }
        do {
            try configureTermios(fd: fd, baudRate: config.baudRate)
        } catch {
            closeFileDescriptor(fd)
            throw error
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        let stream = AsyncThrowingStream<[UInt8], Error> { continuation = $0 }
        do {
            let channel = try await NIOPipeBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(SerialBridgeHandler(continuation: continuation))
                }
                .takingOwnershipOfDescriptor(inputOutput: fd)
                .get()
            // Kanalen äger `fd` från och med nu (NIOPipeBootstraps
            // "takingOwnershipOf..."-namn är bokstavligt — den stänger fd
            // själv i close()). Gruppen ägs av sessionen, stängs i close().
            return SerialSession(channel: channel, group: group, output: stream)
        } catch {
            closeFileDescriptor(fd)
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func send(_ bytes: [UInt8]) {
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        channel.writeAndFlush(buf, promise: nil)
    }

    public func send(_ text: String) {
        send(Array(text.utf8))
    }

    public func close() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    /// De vanligaste standardbaudhastigheterna — gemensamma för både Darwin
    /// och Glibcs `termios.h`-konstanter (ovanligare/plattformsspecifika
    /// hastigheter som 460800/921600 stöds medvetet inte här).
    public static let commonBaudRates: [UInt32] = [
        300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400,
    ]

    private static func speed(for baudRate: UInt32) throws -> speed_t {
        switch baudRate {
        case 300: return speed_t(B300)
        case 1200: return speed_t(B1200)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: throw SerialError.unsupportedBaudRate(baudRate)
        }
    }

    /// Sätter porten i "rått" läge (`cfmakeraw`: ingen kanonisk radbuffring,
    /// inget lokalt eko, inga signalkontrolltecken tolkade) — exakt det en
    /// generisk terminalvy mot godtycklig seriell utrustning behöver, samma
    /// resonemang som `TelnetIACFilter`s "avvisa alla NVT-alternativ".
    /// `CLOCAL`/`CREAD` sätts explicit: ignorera modemstatuslinjer och
    /// aktivera mottagning — utan dem kan `open()` blockera eller kanalen
    /// aldrig ta emot data på vissa seriella drivrutiner.
    private static func configureTermios(fd: Int32, baudRate: UInt32) throws {
        var raw = termios()
        guard tcgetattr(fd, &raw) == 0 else {
            throw SerialError.configurationFailed("tcgetattr misslyckades")
        }
        cfmakeraw(&raw)
        let spd = try speed(for: baudRate)
        cfsetispeed(&raw, spd)
        cfsetospeed(&raw, spd)
        raw.c_cflag |= tcflag_t(CLOCAL) | tcflag_t(CREAD)
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else {
            throw SerialError.configurationFailed("tcsetattr misslyckades")
        }
    }
}

/// Ren pass-through: rå byte-ström åt båda hållen, inget protokoll att
/// tolka (till skillnad från `TelnetIACHandler`) — den seriella porten är
/// redan i rått läge tack vare `configureTermios`.
final class SerialBridgeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    init(continuation: AsyncThrowingStream<[UInt8], Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            continuation.yield(bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

/// Listar sannolika seriella enheter för en "välj port"-UI — best-effort,
/// ingen garanti att en listad enhet faktiskt är en riktig seriell adapter
/// (t.ex. macOS `/dev/cu.Bluetooth-Incoming-Port` dyker upp men är sällan
/// relevant). Enkel katalogglob, inget beroende på `IOKit`/`udev`.
public enum SerialPortLister {
    public static func availablePaths() -> [String] {
        let dir = "/dev"
        guard let entries = try? FileManagerLite.contents(ofDirectory: dir) else { return [] }
        let prefixes: [String]
        #if canImport(Darwin)
        prefixes = ["cu.", "tty."]
        #else
        prefixes = ["ttyUSB", "ttyACM", "ttyS"]
        #endif
        return entries
            .filter { name in prefixes.contains { name.hasPrefix($0) } }
            .sorted()
            .map { "\(dir)/\($0)" }
    }
}

/// Minimal katalogläsning utan `Foundation` — hela filen undviker medvetet
/// `import Foundation` (bara POSIX/NIO), samma stil som `Telnet.swift`.
private enum FileManagerLite {
    static func contents(ofDirectory path: String) throws -> [String] {
        guard let dir = opendir(path) else {
            throw SerialError.openFailed(path)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: ptr)
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }
}
#endif
