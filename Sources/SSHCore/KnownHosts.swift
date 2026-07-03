import Foundation
import NIOConcurrencyHelpers

/// Lagrar sedda värdnycklar (Trust-On-First-Use). Första gången en värd ses
/// lärs nyckeln in; nästa gång jämförs den. En ändrad nyckel är en varningssignal
/// (MITM eller ombyggd server) och avvisas.
///
/// Filformat (en rad per värd): `host:port ssh-ed25519 AAAA...`
/// Standardplats: `~/.bastion/known_hosts`. `path: nil` = endast i minne (test).
public final class KnownHosts {
    public enum Verdict: Sendable, Equatable {
        case trusted                    // matchar lagrad nyckel
        case learned                    // ny värd — nu inlärd
        case changed(stored: String)    // skiljer sig från lagrad nyckel
    }

    private let path: String?
    private let lock = NIOLock()
    private var entries: [String: String]

    public static var defaultPath: String {
        (("~/.bastion/known_hosts") as NSString).expandingTildeInPath
    }

    public init(path: String? = KnownHosts.defaultPath) {
        self.path = path
        self.entries = KnownHosts.loadEntries(path: path)
    }

    private static func loadEntries(path: String?) -> [String: String] {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = String(parts[1])
        }
        return out
    }

    /// Avgör hur en presenterad nyckel förhåller sig till vad vi sett tidigare.
    /// Lär in nyckeln (och persisterar) om värden är ny.
    public func check(host: String, port: Int, keyString: String) -> Verdict {
        let id = "\(host):\(port)"
        return lock.withLock {
            if let stored = entries[id] {
                return stored == keyString ? .trusted : .changed(stored: stored)
            }
            entries[id] = keyString
            append(id: id, keyString: keyString)
            return .learned
        }
    }

    // Anropas med låset hållet.
    private func append(id: String, keyString: String) {
        guard let path else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let line = "\(id) \(keyString)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}
