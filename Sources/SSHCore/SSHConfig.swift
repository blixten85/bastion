import Foundation

/// Uppslaget resultat för ett värdalias ur `~/.ssh/config`.
public struct ResolvedHost: Sendable, Equatable {
    public var hostName: String
    public var user: String?
    public var port: Int
    public var identityFile: String?
    public var proxyJump: String?
}

/// Minimal läsare av OpenSSH:s klientkonfiguration (`~/.ssh/config`). Stöder
/// `Host`-block med jokertecken (`*`, `?`) och negation (`!`), samt de vanligaste
/// nycklarna. Semantik enligt OpenSSH: **första värdet vinner** per nyckel.
/// `Match`-block hoppas medvetet över (ännu ej stött).
public struct SSHConfig: Sendable {
    private enum Entry: Sendable {
        case host([String])
        case setting(String, String)
    }
    private let entries: [Entry]

    public static var defaultPath: String {
        (("~/.ssh/config") as NSString).expandingTildeInPath
    }

    public init(text: String) {
        var out: [Entry] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let (key, value) = SSHConfig.tokenize(String(rawLine)) else { continue }
            switch key {
            case "host":
                out.append(.host(value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)))
            case "match":
                // Ej stött — tomt mönster matchar aldrig, så blockets nycklar ignoreras.
                out.append(.host([]))
            default:
                out.append(.setting(key, value))
            }
        }
        self.entries = out
    }

    public static func load(path: String = SSHConfig.defaultPath) -> SSHConfig {
        SSHConfig(text: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    /// Konkreta värdalias (inte jokertecken/negation) i den ordning de står —
    /// underlag för att importera värdar till host-databasen.
    public var hostAliases: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries {
            guard case .host(let patterns) = entry else { continue }
            for p in patterns where !p.contains("*") && !p.contains("?") && !p.hasPrefix("!") {
                if seen.insert(p).inserted { out.append(p) }
            }
        }
        return out
    }

    /// Slår upp ett alias. Nycklar före första `Host` är globala (gäller alla).
    public func resolve(_ alias: String) -> ResolvedHost {
        var found: [String: String] = [:]
        var active = true  // global sektion tills första Host/Match
        for entry in entries {
            switch entry {
            case .host(let patterns):
                active = SSHConfig.hostMatches(patterns, alias)
            case .setting(let key, let value):
                if active, found[key] == nil { found[key] = value }
            }
        }
        return ResolvedHost(
            hostName: found["hostname"] ?? alias,
            user: found["user"],
            port: found["port"].flatMap { Int($0) } ?? 22,
            identityFile: found["identityfile"].map {
                ($0 as NSString).expandingTildeInPath
            },
            proxyJump: found["proxyjump"])
    }

    // MARK: - Parsning

    /// Delar en rad i (nyckel-gemener, värde). Stöder `Key Value`, `Key=Value`,
    /// `Key = Value` och citerade värden. Returnerar nil för tomma/kommentarrader.
    static func tokenize(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        guard let sep = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (trimmed.lowercased(), "")
        }
        let key = String(trimmed[..<sep]).lowercased()
        var value = String(trimmed[trimmed.index(after: sep)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    /// En värd matchar om minst ett positivt mönster matchar och inget negerat gör det.
    static func hostMatches(_ patterns: [String], _ host: String) -> Bool {
        guard !patterns.isEmpty else { return false }
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), host) { return false }
            } else if glob(pattern, host) {
                matched = true
            }
        }
        return matched
    }

    /// Jokertecken-matchning med `*` (noll+ tecken) och `?` (exakt ett tecken).
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
