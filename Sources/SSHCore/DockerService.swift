import Foundation

// Docker-hantering över SSH. Kommandobyggarna och parsningen är rena funktioner
// (testbara); SSH-lagret är tunt ovanpå. Containerreferenser VALIDERAS innan de
// sätts in i ett shell-kommando — annars vore "name; rm -rf /" en injektion.

public enum DockerError: Error, Sendable, Equatable {
    case invalidReference(String)
}

public enum DockerService {
    /// Docker-namn: [a-zA-Z0-9][a-zA-Z0-9_.-]*. Korta/långa id:n är hex. Vi kräver
    /// att första tecknet är alfanumeriskt (utesluter även "-flagg"-injektion) och
    /// att resten bara är säkra tecken. Allt annat avvisas.
    static let referencePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]*$")

    public static func validate(_ ref: String) throws -> String {
        let range = NSRange(ref.startIndex..<ref.endIndex, in: ref)
        guard ref.count <= 128, referencePattern.firstMatch(in: ref, range: range) != nil else {
            throw DockerError.invalidReference(ref)
        }
        return ref
    }

    // MARK: - Kommandon

    static let listFormat = "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}"

    public static func listCommand(all: Bool) -> String {
        "docker ps\(all ? " -a" : "") --format '\(listFormat)' 2>/dev/null"
    }

    public static func startCommand(_ ref: String) throws -> String {
        "docker start \(try validate(ref))"
    }

    public static func stopCommand(_ ref: String) throws -> String {
        "docker stop \(try validate(ref))"
    }

    public static func restartCommand(_ ref: String) throws -> String {
        "docker restart \(try validate(ref))"
    }

    public static func logsCommand(_ ref: String, tail: Int) throws -> String {
        let n = max(1, tail)
        return "docker logs --tail \(n) \(try validate(ref)) 2>&1"
    }

    /// Interaktiv shell i en container. Körs via en PTY-kanal (`SSHSession.openShell`),
    /// därav `-it`. Faller tillbaka till `sh` om `bash` saknas.
    public static func execShellCommand(_ ref: String) throws -> String {
        let r = try validate(ref)
        return "docker exec -it \(r) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
    }

    public static func parseList(_ output: String) -> [DockerContainer] {
        output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { raw in
            let f = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, !f[0].isEmpty else { return nil }
            return DockerContainer(id: f[0], name: f[1], image: f[2], status: f[3])
        }
    }

    // MARK: - Körning över SSH

    public static func list(over session: SSHSession, all: Bool = true) async throws -> [DockerContainer] {
        parseList(try await session.run(listCommand(all: all)))
    }

    public static func start(_ ref: String, over session: SSHSession) async throws {
        _ = try await session.run(startCommand(ref))
    }

    public static func stop(_ ref: String, over session: SSHSession) async throws {
        _ = try await session.run(stopCommand(ref))
    }

    public static func restart(_ ref: String, over session: SSHSession) async throws {
        _ = try await session.run(restartCommand(ref))
    }

    public static func logs(_ ref: String, tail: Int = 200, over session: SSHSession) async throws -> String {
        try await session.run(logsCommand(ref, tail: tail))
    }
}
