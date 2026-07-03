import Foundation

// Dashboard-data hämtad agentlöst över SSH: ett kombinerat kommando ger en
// ögonblicksbild av värden (last, minne, disk, drifttid, OS, Docker). Parsningen
// är rena funktioner (sträng -> struct) och testas med fixtures; SSH-lagret är
// tunt ovanpå.

public struct LoadAverage: Codable, Sendable, Equatable {
    public var one: Double
    public var five: Double
    public var fifteen: Double
}

public struct MemoryInfo: Codable, Sendable, Equatable {
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

public struct DiskUsage: Codable, Sendable, Equatable {
    public var filesystem: String
    public var mount: String
    public var sizeBytes: Int64
    public var usedBytes: Int64
    public var availableBytes: Int64
    public var capacityPercent: Int
}

public struct DockerContainer: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var image: String
    public var status: String

    /// Härleds ur statustexten ("Up 3 days" = igång, "Exited (0)…" = stoppad).
    public var isRunning: Bool { status.hasPrefix("Up") }
}

public struct SystemSnapshot: Codable, Sendable, Equatable {
    public var hostname: String?
    public var os: String?
    public var kernel: String?
    public var cpuCount: Int?
    public var uptimeSeconds: Double?
    public var load: LoadAverage?
    public var memory: MemoryInfo?
    public var disks: [DiskUsage] = []
    public var containers: [DockerContainer] = []

    /// Rot-filsystemet, om det finns — det UI:t oftast visar först.
    public var rootDisk: DiskUsage? { disks.first { $0.mount == "/" } }
}

public enum SystemProbe {
    /// Ett kommando, en round-trip. Sektionsmarkörer (@@NAMN) skiljer utdata åt.
    /// Allt är läsning; saknade verktyg (docker, nproc) sväljs tyst.
    public static let command: String = [
        "echo @@LOADAVG", "cat /proc/loadavg 2>/dev/null",
        "echo @@UPTIME", "cat /proc/uptime 2>/dev/null",
        "echo @@MEM", "cat /proc/meminfo 2>/dev/null",
        "echo @@DF", "df -kP 2>/dev/null",
        "echo @@OS", "cat /etc/os-release 2>/dev/null",
        "echo @@KERNEL", "uname -sr 2>/dev/null",
        "echo @@HOST", "cat /proc/sys/kernel/hostname 2>/dev/null",
        "echo @@NPROC", "nproc 2>/dev/null",
        "echo @@DOCKER", "docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null",
        "echo @@END",
    ].joined(separator: "; ")

    /// Kör proben över en ansluten session.
    public static func snapshot(over session: SSHSession) async throws -> SystemSnapshot {
        parse(try await session.run(command))
    }

    // MARK: - Parsning

    public static func parse(_ output: String) -> SystemSnapshot {
        var sections: [String: [String]] = [:]
        var current = ""
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                current = String(line.dropFirst(2))
                if sections[current] == nil { sections[current] = [] }
            } else if !current.isEmpty {
                sections[current, default: []].append(line)
            }
        }

        var snap = SystemSnapshot()
        snap.load = parseLoad(sections["LOADAVG"]?.first)
        snap.uptimeSeconds = sections["UPTIME"]?.first?
            .split(separator: " ").first.flatMap { Double($0) }
        snap.memory = parseMemory(sections["MEM"] ?? [])
        snap.disks = parseDisks(sections["DF"] ?? [])
        snap.os = parseOS(sections["OS"] ?? [])
        snap.kernel = sections["KERNEL"]?.first?.trimmingCharacters(in: .whitespaces).nonEmpty
        snap.hostname = sections["HOST"]?.first?.trimmingCharacters(in: .whitespaces).nonEmpty
        snap.cpuCount = sections["NPROC"]?.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        snap.containers = parseDocker(sections["DOCKER"] ?? [])
        return snap
    }

    private static func parseLoad(_ line: String?) -> LoadAverage? {
        let parts = line?.split(separator: " ").compactMap { Double($0) } ?? []
        guard parts.count >= 3 else { return nil }
        return LoadAverage(one: parts[0], five: parts[1], fifteen: parts[2])
    }

    private static func parseMemory(_ lines: [String]) -> MemoryInfo? {
        var kb: [String: Int64] = [:]
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2 else { continue }
            let key = f[0].hasSuffix(":") ? String(f[0].dropLast()) : String(f[0])
            if let v = Int64(f[1]) { kb[key] = v }
        }
        guard let total = kb["MemTotal"], let avail = kb["MemAvailable"] else { return nil }
        return MemoryInfo(totalBytes: total * 1024, availableBytes: avail * 1024)
    }

    private static func parseDisks(_ lines: [String]) -> [DiskUsage] {
        var out: [DiskUsage] = []
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 6, f[0] != "Filesystem" else { continue }
            guard let blocks = Int64(f[1]), let used = Int64(f[2]), let avail = Int64(f[3]) else { continue }
            let cap = Int(f[4].replacingOccurrences(of: "%", with: "")) ?? 0
            out.append(DiskUsage(
                filesystem: f[0], mount: f[5...].joined(separator: " "),
                sizeBytes: blocks * 1024, usedBytes: used * 1024,
                availableBytes: avail * 1024, capacityPercent: cap))
        }
        return out
    }

    private static func parseOS(_ lines: [String]) -> String? {
        for line in lines where line.hasPrefix("PRETTY_NAME=") {
            var v = String(line.dropFirst("PRETTY_NAME=".count))
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            return v.nonEmpty
        }
        return nil
    }

    private static func parseDocker(_ lines: [String]) -> [DockerContainer] {
        lines.compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { return nil }
            return DockerContainer(id: f[0], name: f[1], image: f[2], status: f[3])
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
