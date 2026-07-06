import NIOCore

// SFTP-trådformatet (SSH File Transfer Protocol version 3, den version
// OpenSSH faktiskt talar — senare utkast höjde versionsnumret men OpenSSH
// stannade på 3). Ren protokollkodning här, ingen kanal/I/O — det ligger i
// SFTPClient.swift (nästa steg). Referens: draft-ietf-secsh-filexfer-02
// (§3-9), som är vad OpenSSHs sftp-server implementerar.

/// SFTP-paket-header: uint32 längd (räknar med typbyten men inte sig själv)
/// + en typbyte. Payloaden efter typbyten är `längd - 1` byte.
public enum SFTPMessageType: UInt8, Sendable {
    case initMsg = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
}

/// SSH_FXF_*-flaggorna till SSH_FXP_OPEN (kan kombineras med bitvis OR).
public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = SFTPOpenFlags(rawValue: 0x01)
    public static let write = SFTPOpenFlags(rawValue: 0x02)
    public static let append = SFTPOpenFlags(rawValue: 0x04)
    public static let create = SFTPOpenFlags(rawValue: 0x08)
    public static let truncate = SFTPOpenFlags(rawValue: 0x10)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

/// SSH_FX_*-statuskoderna i SSH_FXP_STATUS-svar.
public enum SFTPStatusCode: Sendable, Equatable, RawRepresentable {
    case ok
    case eof
    case noSuchFile
    case permissionDenied
    case failure
    case badMessage
    case noConnection
    case connectionLost
    case opUnsupported
    /// Okänd kod från servern (framtida version/utökning) — bevarar den
    /// faktiska rawValue istället för att kollapsa alla okända koder till
    /// samma värde (CodeRabbit-fynd, PR #37: raden sa att rawValue bevarades
    /// men `.unknown = 0xFFFF_FFFF` gjorde precis motsatsen).
    case unknown(UInt32)

    public init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .ok
        case 1: self = .eof
        case 2: self = .noSuchFile
        case 3: self = .permissionDenied
        case 4: self = .failure
        case 5: self = .badMessage
        case 6: self = .noConnection
        case 7: self = .connectionLost
        case 8: self = .opUnsupported
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt32 {
        switch self {
        case .ok: return 0
        case .eof: return 1
        case .noSuchFile: return 2
        case .permissionDenied: return 3
        case .failure: return 4
        case .badMessage: return 5
        case .noConnection: return 6
        case .connectionLost: return 7
        case .opUnsupported: return 8
        case .unknown(let raw): return raw
        }
    }
}

public struct SFTPStatusError: Error, Sendable, Equatable {
    public let code: SFTPStatusCode
    public let message: String
}

/// Filattribut (SSH_FILEXFER_ATTR_*-flaggorna avkodade till optionals —
/// `nil` betyder "flaggan var inte satt", inte "värdet är noll").
public struct SFTPFileAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?

    public init(
        size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil,
        permissions: UInt32? = nil, accessTime: UInt32? = nil, modificationTime: UInt32? = nil
    ) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    private struct Flags: OptionSet {
        let rawValue: UInt32
        static let size = Flags(rawValue: 0x0000_0001)
        static let uidgid = Flags(rawValue: 0x0000_0002)
        static let permissions = Flags(rawValue: 0x0000_0004)
        static let acmodtime = Flags(rawValue: 0x0000_0008)
        static let extended = Flags(rawValue: 0x8000_0000)
    }

    func encode(into buffer: inout ByteBuffer) {
        // uid/gid och accessTime/modificationTime är par i v3-trådformatet —
        // om bara den ena hälften sattes skrev den gamla koden en falsk 0:a
        // för den andra istället för att upptäcka den felaktiga anropen
        // (CodeRabbit-fynd, PR #37).
        precondition((uid == nil) == (gid == nil), "uid och gid måste ges tillsammans")
        precondition(
            (accessTime == nil) == (modificationTime == nil),
            "accessTime och modificationTime måste ges tillsammans")

        var flags: Flags = []
        if size != nil { flags.insert(.size) }
        if uid != nil { flags.insert(.uidgid) }
        if permissions != nil { flags.insert(.permissions) }
        if accessTime != nil { flags.insert(.acmodtime) }
        buffer.writeInteger(flags.rawValue)
        if let size { buffer.writeInteger(size) }
        if let uid, let gid {
            buffer.writeInteger(uid)
            buffer.writeInteger(gid)
        }
        if let permissions { buffer.writeInteger(permissions) }
        if let accessTime, let modificationTime {
            buffer.writeInteger(accessTime)
            buffer.writeInteger(modificationTime)
        }
        // Extended-par (flags & extended) skrivs aldrig av oss — vi sätter
        // aldrig den flaggan i encode(), så det finns inget att skriva här.
    }

    static func decode(from buffer: inout ByteBuffer) throws -> SFTPFileAttributes {
        guard let rawFlags: UInt32 = buffer.readInteger() else {
            throw SFTPProtocolError.truncatedMessage
        }
        let flags = Flags(rawValue: rawFlags)
        var attrs = SFTPFileAttributes()
        if flags.contains(.size) {
            guard let size: UInt64 = buffer.readInteger() else { throw SFTPProtocolError.truncatedMessage }
            attrs.size = size
        }
        if flags.contains(.uidgid) {
            guard let uid: UInt32 = buffer.readInteger(), let gid: UInt32 = buffer.readInteger() else {
                throw SFTPProtocolError.truncatedMessage
            }
            attrs.uid = uid
            attrs.gid = gid
        }
        if flags.contains(.permissions) {
            guard let permissions: UInt32 = buffer.readInteger() else { throw SFTPProtocolError.truncatedMessage }
            attrs.permissions = permissions
        }
        if flags.contains(.acmodtime) {
            guard let atime: UInt32 = buffer.readInteger(), let mtime: UInt32 = buffer.readInteger() else {
                throw SFTPProtocolError.truncatedMessage
            }
            attrs.accessTime = atime
            attrs.modificationTime = mtime
        }
        if flags.contains(.extended) {
            guard let count: UInt32 = buffer.readInteger() else { throw SFTPProtocolError.truncatedMessage }
            for _ in 0..<count {
                _ = try buffer.readSFTPString()
                _ = try buffer.readSFTPString()
            }
        }
        return attrs
    }

    // POSIX st_mode-filtypsbitar — riktiga SFTP-servrar (inte bara
    // behörighetsbitarna) inkluderar dem i `permissions`-fältet, så en
    // klient kan skilja mapp från fil utan ett extra STAT-anrop per post.
    private static let typeMask: UInt32 = 0o170000
    private static let directoryType: UInt32 = 0o040000
    private static let symlinkType: UInt32 = 0o120000

    public var isDirectory: Bool {
        guard let permissions else { return false }
        return (permissions & Self.typeMask) == Self.directoryType
    }

    public var isSymbolicLink: Bool {
        guard let permissions else { return false }
        return (permissions & Self.typeMask) == Self.symlinkType
    }
}

public struct SFTPNameEntry: Equatable, Sendable {
    public let filename: String
    public let longname: String
    public let attributes: SFTPFileAttributes
}

public enum SFTPProtocolError: Error, Sendable, Equatable {
    case truncatedMessage
    case unexpectedMessageType(UInt8)
}

extension ByteBuffer {
    /// SFTP-"string" = uint32 längd + råa byte (UTF-8 för sökvägar/namn,
    /// inte nödvändigtvis giltig UTF-8 för READ/WRITE-datapayloads — därför
    /// finns readSFTPStringBytes() separat för det fallet).
    mutating func writeSFTPString(_ string: String) {
        var utf8 = ByteBuffer(string: string)
        self.writeInteger(UInt32(utf8.readableBytes))
        self.writeBuffer(&utf8)
    }

    mutating func writeSFTPBytes(_ bytes: [UInt8]) {
        self.writeInteger(UInt32(bytes.count))
        self.writeBytes(bytes)
    }

    mutating func readSFTPString() throws -> String {
        guard let length: UInt32 = self.readInteger(),
              let string = self.readString(length: Int(length))
        else { throw SFTPProtocolError.truncatedMessage }
        return string
    }

    mutating func readSFTPBytes() throws -> [UInt8] {
        guard let length: UInt32 = self.readInteger(),
              let bytes = self.readBytes(length: Int(length))
        else { throw SFTPProtocolError.truncatedMessage }
        return bytes
    }
}

/// Bygger ett komplett SFTP-paket (längdprefix + typbyte + payload) ur en
/// payload-skrivande closure — delad av alla request-encoders nedan så
/// längdberäkningen aldrig görs fel/glöms.
func makeSFTPPacket(type: SFTPMessageType, _ writePayload: (inout ByteBuffer) -> Void) -> ByteBuffer {
    var payload = ByteBuffer()
    writePayload(&payload)
    var packet = ByteBuffer()
    packet.writeInteger(UInt32(payload.readableBytes + 1))
    packet.writeInteger(type.rawValue)
    packet.writeBuffer(&payload)
    return packet
}

public enum SFTPRequest {
    public static func initMessage(version: UInt32) -> ByteBuffer {
        makeSFTPPacket(type: .initMsg) { $0.writeInteger(version) }
    }

    public static func open(id: UInt32, path: String, flags: SFTPOpenFlags, attributes: SFTPFileAttributes = .init()) -> ByteBuffer {
        makeSFTPPacket(type: .open) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
            buf.writeInteger(flags.rawValue)
            attributes.encode(into: &buf)
        }
    }

    public static func close(id: UInt32, handle: [UInt8]) -> ByteBuffer {
        makeSFTPPacket(type: .close) { buf in
            buf.writeInteger(id)
            buf.writeSFTPBytes(handle)
        }
    }

    public static func read(id: UInt32, handle: [UInt8], offset: UInt64, length: UInt32) -> ByteBuffer {
        makeSFTPPacket(type: .read) { buf in
            buf.writeInteger(id)
            buf.writeSFTPBytes(handle)
            buf.writeInteger(offset)
            buf.writeInteger(length)
        }
    }

    public static func write(id: UInt32, handle: [UInt8], offset: UInt64, data: [UInt8]) -> ByteBuffer {
        makeSFTPPacket(type: .write) { buf in
            buf.writeInteger(id)
            buf.writeSFTPBytes(handle)
            buf.writeInteger(offset)
            buf.writeSFTPBytes(data)
        }
    }

    public static func opendir(id: UInt32, path: String) -> ByteBuffer {
        makeSFTPPacket(type: .opendir) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
        }
    }

    public static func readdir(id: UInt32, handle: [UInt8]) -> ByteBuffer {
        makeSFTPPacket(type: .readdir) { buf in
            buf.writeInteger(id)
            buf.writeSFTPBytes(handle)
        }
    }

    public static func remove(id: UInt32, path: String) -> ByteBuffer {
        makeSFTPPacket(type: .remove) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
        }
    }

    public static func mkdir(id: UInt32, path: String, attributes: SFTPFileAttributes = .init()) -> ByteBuffer {
        makeSFTPPacket(type: .mkdir) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
            attributes.encode(into: &buf)
        }
    }

    public static func rmdir(id: UInt32, path: String) -> ByteBuffer {
        makeSFTPPacket(type: .rmdir) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
        }
    }

    public static func realpath(id: UInt32, path: String) -> ByteBuffer {
        makeSFTPPacket(type: .realpath) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
        }
    }

    public static func stat(id: UInt32, path: String) -> ByteBuffer {
        makeSFTPPacket(type: .stat) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
        }
    }

    public static func lstat(id: UInt32, path: String) -> ByteBuffer {
        makeSFTPPacket(type: .lstat) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
        }
    }

    public static func rename(id: UInt32, oldPath: String, newPath: String) -> ByteBuffer {
        makeSFTPPacket(type: .rename) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(oldPath)
            buf.writeSFTPString(newPath)
        }
    }

    public static func setstat(id: UInt32, path: String, attributes: SFTPFileAttributes) -> ByteBuffer {
        makeSFTPPacket(type: .setstat) { buf in
            buf.writeInteger(id)
            buf.writeSFTPString(path)
            attributes.encode(into: &buf)
        }
    }
}

/// Ett avkodat svarspaket från servern — id ingår inte här, den läses ut
/// separat av anroparen (klienten matchar id mot sin pending-request-tabell).
public enum SFTPResponse: Equatable {
    case version(UInt32)
    case status(id: UInt32, code: SFTPStatusCode, message: String)
    case handle(id: UInt32, handle: [UInt8])
    case data(id: UInt32, bytes: [UInt8])
    case name(id: UInt32, entries: [SFTPNameEntry])
    case attrs(id: UInt32, attributes: SFTPFileAttributes)

    /// Läser EN komplett SFTP-payload (utan längdprefix och typbyte — de
    /// har redan konsumerats av anroparen, som behöver typen för att veta
    /// vilken gren av `SFTPResponse` att avkoda till).
    static func decode(type: SFTPMessageType, from buffer: inout ByteBuffer) throws -> SFTPResponse {
        switch type {
        case .version:
            guard let version: UInt32 = buffer.readInteger() else { throw SFTPProtocolError.truncatedMessage }
            return .version(version)
        case .status:
            guard let id: UInt32 = buffer.readInteger(), let rawCode: UInt32 = buffer.readInteger() else {
                throw SFTPProtocolError.truncatedMessage
            }
            // try? dolde tidigare trunkerade/ogiltiga STATUS-meddelanden, och
            // v3:s language-tag-sträng lästes aldrig (CodeRabbit-fynd, PR #37).
            let message = try buffer.readSFTPString()
            _ = try buffer.readSFTPString()  // language-tag, används inte
            let code = SFTPStatusCode(rawValue: rawCode)
            return .status(id: id, code: code, message: message)
        case .handle:
            guard let id: UInt32 = buffer.readInteger() else { throw SFTPProtocolError.truncatedMessage }
            let handle = try buffer.readSFTPBytes()
            return .handle(id: id, handle: handle)
        case .data:
            guard let id: UInt32 = buffer.readInteger() else { throw SFTPProtocolError.truncatedMessage }
            let bytes = try buffer.readSFTPBytes()
            return .data(id: id, bytes: bytes)
        case .name:
            guard let id: UInt32 = buffer.readInteger(), let count: UInt32 = buffer.readInteger() else {
                throw SFTPProtocolError.truncatedMessage
            }
            // count är obetrodd tråddata — reserveCapacity(Int(count)) kunde
            // tidigare försöka en enorm allokering innan paketets giltighet
            // ens bevisats (CodeRabbit-fynd, PR #37).
            let minimumEncodedEntryBytes = 12  // filnamnslängd + longname-längd + attrs-flaggor
            guard UInt64(count) <= UInt64(buffer.readableBytes / minimumEncodedEntryBytes) else {
                throw SFTPProtocolError.truncatedMessage
            }
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                let filename = try buffer.readSFTPString()
                let longname = try buffer.readSFTPString()
                let attrs = try SFTPFileAttributes.decode(from: &buffer)
                entries.append(SFTPNameEntry(filename: filename, longname: longname, attributes: attrs))
            }
            return .name(id: id, entries: entries)
        case .attrs:
            guard let id: UInt32 = buffer.readInteger() else { throw SFTPProtocolError.truncatedMessage }
            let attrs = try SFTPFileAttributes.decode(from: &buffer)
            return .attrs(id: id, attributes: attrs)
        case .initMsg, .open, .close, .read, .write, .lstat, .fstat, .setstat, .fsetstat,
             .opendir, .readdir, .remove, .mkdir, .rmdir, .realpath, .rename, .stat:
            // Request-typer — kommer aldrig från servern som ett svar.
            throw SFTPProtocolError.unexpectedMessageType(type.rawValue)
        }
    }
}
