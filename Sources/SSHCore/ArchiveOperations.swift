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

    /// `zip`, till skillnad från `tar -f`, tar arkivnamnet som ett RENT
    /// positionellt argument — inte kopplat till en flagga som konsumerar
    /// sitt värde oavsett innehåll. Två separata, EMPIRISKT verifierade
    /// (2026-07-08, CodeRabbit-fynd, #125) motmedel krävs därför:
    /// 1. `--` FÖRE sökvägslistan (EFTER arkivnamnet — `zip` vägrar uttryckligen
    ///    "-- before archive name") skyddar filnamn som börjar med `-`
    ///    (t.ex. en fil döpt `-T`, som annars tolkas som zips egen
    ///    testarkiv-flagga och ger "Nothing to do!" istället för att
    ///    packas).
    /// 2. `./`-prefix på arkivnamnet SJÄLVT (helt användarstyrt i UI:t)
    ///    löser samma problem för namnet — `--` fungerar INTE där (zip
    ///    vägrar starta), men `./-namn.zip` gör namnet otvetydigt till en
    ///    sökväg istället för en flaggsträng.
    public static func createZipCommand(paths: [String], archiveName: String, in directory: String) -> String {
        let quotedPaths = paths.map(shellQuote).joined(separator: " ")
        let safeArchiveName = "./" + archiveName
        return "cd \(shellQuote(directory)) && zip -r -q \(shellQuote(safeArchiveName)) -- \(quotedPaths)"
    }

    /// Samma `./`-prefix-behov som `createZipCommand` — `unzip` tolkar ett
    /// arkivnamn som börjar med `-` som en flaggsträng, TYST (den skriver
    /// bara ut sin hjälptext och avslutar med kod 0 — ser ut som en
    /// lyckad körning men extraherar ingenting alls, verifierat
    /// empiriskt, 2026-07-08).
    public static func extractZipCommand(archiveName: String, in directory: String) -> String {
        "cd \(shellQuote(directory)) && unzip -o -q \(shellQuote("./" + archiveName))"
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
