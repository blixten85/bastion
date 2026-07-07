import Foundation

// Arkivoperationer (komprimera/packa upp) för SFTP-filhanteraren. SFTP
// version 3 har ingen egen arkivsemantik — det här shellar ut till tar/zip
// över en vanlig exec-kanal, samma mönster som DockerService.swift.
// Sökvägar VALIDERAS INTE mot en whitelist (som DockerService gör för
// containerreferenser) eftersom filnamn legitimt kan innehålla mellanslag/
// unicode/etc — istället citeras varje sökväg för sig med enkla citattecken
// (POSIX-shell-säkert), annars vore en fil döpt `"; rm -rf ~ #"` en injektion.

public enum ArchiveOperations {
    /// Enkla citattecken runt `s`, med inbäddade `'` eskapade som `'\''`
    /// (stänger citatet, ett litterlat-eskapat citattecken, öppnar igen) —
    /// standard POSIX-shell-säkert sätt att citera GODTYCKLIG text, oavsett
    /// mellanslag eller specialtecken.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func createTarGzCommand(paths: [String], archiveName: String, in directory: String) -> String {
        let quotedPaths = paths.map(shellQuote).joined(separator: " ")
        return "cd \(shellQuote(directory)) && tar czf \(shellQuote(archiveName)) -- \(quotedPaths)"
    }

    public static func extractTarGzCommand(archiveName: String, in directory: String) -> String {
        "cd \(shellQuote(directory)) && tar xzf \(shellQuote(archiveName))"
    }

    public static func createZipCommand(paths: [String], archiveName: String, in directory: String) -> String {
        let quotedPaths = paths.map(shellQuote).joined(separator: " ")
        return "cd \(shellQuote(directory)) && zip -r -q \(shellQuote(archiveName)) \(quotedPaths)"
    }

    public static func extractZipCommand(archiveName: String, in directory: String) -> String {
        "cd \(shellQuote(directory)) && unzip -o -q \(shellQuote(archiveName))"
    }

    // MARK: - Körning över SSH

    public static func createTarGz(
        paths: [String], archiveName: String, in directory: String, over session: SSHSession
    ) async throws {
        _ = try await session.run(createTarGzCommand(paths: paths, archiveName: archiveName, in: directory))
    }

    public static func extractTarGz(archiveName: String, in directory: String, over session: SSHSession) async throws {
        _ = try await session.run(extractTarGzCommand(archiveName: archiveName, in: directory))
    }

    public static func createZip(
        paths: [String], archiveName: String, in directory: String, over session: SSHSession
    ) async throws {
        _ = try await session.run(createZipCommand(paths: paths, archiveName: archiveName, in: directory))
    }

    public static func extractZip(archiveName: String, in directory: String, over session: SSHSession) async throws {
        _ = try await session.run(extractZipCommand(archiveName: archiveName, in: directory))
    }
}
