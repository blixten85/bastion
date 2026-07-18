import Foundation
import NIOCore
import NIOPosix

/// Wake-on-LAN — bygger och skickar ett "magic packet" för att väcka en
/// avstängd/vilande maskin på det lokala nätverket. Ren UDP, ingen SSH-
/// koppling alls (till skillnad från resten av SSHCore), men hör hemma här
/// av samma skäl som Tailscale/WireGuard-stödet: en funktion Termius saknar,
/// relevant för hemmalabb-användare som vill väcka en server innan de SSH:ar
/// in på den.
public enum WakeOnLanError: Error, Equatable {
    case invalidMACAddress(String)
    /// `port` utanför `1...65_535` — plattformens sockets-lager tolkar
    /// annars ofta talet modulo 65536 istället för att kasta (t.ex. 70000
    /// blir 4464 på Linux), vilket tyst skulle skicka paketet till FEL port
    /// istället för att misslyckas synligt (cubic-fynd, PR #173).
    case invalidPort(Int)
}

public enum WakeOnLan {
    /// Parsar en MAC-adress i valfritt vanligt format (`:`, `-` eller inget
    /// separatortecken, skiftlägesokänsligt) till 6 råa bytes.
    public static func parseMAC(_ mac: String) throws -> [UInt8] {
        let cleaned = mac.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard cleaned.count == 12, cleaned.allSatisfy({ $0.isHexDigit }) else {
            throw WakeOnLanError.invalidMACAddress(mac)
        }
        var bytes: [UInt8] = []
        var idx = cleaned.startIndex
        for _ in 0..<6 {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else {
                throw WakeOnLanError.invalidMACAddress(mac)
            }
            bytes.append(byte)
            idx = next
        }
        return bytes
    }

    /// Det klassiska magic packet-formatet: 6 bytes `0xFF` följt av
    /// MAC-adressen upprepad 16 gånger (102 bytes totalt).
    public static func magicPacket(for mac: String) throws -> [UInt8] {
        let macBytes = try parseMAC(mac)
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: macBytes) }
        return packet
    }

    /// Skickar magic packet via UDP-broadcast. `broadcastAddress` är
    /// nätverkets broadcast-adress (t.ex. `192.168.1.255`), inte målets egen
    /// IP — enheten svarar inte på ARP i sovande/avstängt läge, så adressering
    /// måste ske via broadcast. Standardport 9 (`discard`) matchar de flesta
    /// WoL-implementationers förväntan, men 7 förekommer också.
    ///
    /// Skapar en egen kortlivad `EventLoopGroup` per anrop istället för att
    /// dela en långlivad — WoL är en sällan använd, användarutlöst
    /// engångsåtgärd (en knapptryckning), inte en het loop, så tråd-
    /// uppstartskostnaden är försumbar mot komplexiteten av att hålla en
    /// delad grupp vid liv för hela appens livstid. `broadcastAddress`
    /// förväntas vara en literal IP (default-värdet är det) — ett
    /// värdnamn hade behövt DNS-uppslagning, som `makeAddressResolvingHost`
    /// kan blockera på trots `async`.
    public static func send(
        mac: String, broadcastAddress: String = "255.255.255.255", port: Int = 9
    ) async throws {
        guard (1...65_535).contains(port) else { throw WakeOnLanError.invalidPort(port) }
        let packet = try magicPacket(for: mac)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_broadcast), value: 1)
                .bind(host: "0.0.0.0", port: 0).get()
            let remote = try SocketAddress.makeAddressResolvingHost(broadcastAddress, port: port)
            var buffer = channel.allocator.buffer(capacity: packet.count)
            buffer.writeBytes(packet)
            do {
                try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: remote, data: buffer))
                try await channel.close()
            } catch {
                try? await channel.close()
                throw error
            }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }
}
