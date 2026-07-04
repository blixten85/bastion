import Foundation

/// Ett sparat kommando med variabler, t.ex. `docker compose restart {{service}}`.
/// Variabler skrivs `{{namn}}` i mallen — inte bara text, kan fyllas i per
/// körning (se VISION.md: "Restart Plex → ssh → docker compose restart plex").
public struct Snippet: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var template: String
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, template: String, modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.template = template
        self.modifiedAt = modifiedAt
    }

    /// Hittar varje `{{ namn }}`-förekomst i mallen (mellanslag runt namnet
    /// tillåtet och trimmas bort), i den ordning de står. Delad av
    /// `variableNames`/`rendered` så de aldrig kan råka gå isär om t.ex.
    /// `{{ service }}` (med mellanslag) skrevs i mallen.
    private var occurrences: [(range: Range<String.Index>, name: String)] {
        var result: [(Range<String.Index>, String)] = []
        var searchStart = template.startIndex
        while let openRange = template.range(of: "{{", range: searchStart..<template.endIndex) {
            guard let closeRange = template.range(of: "}}", range: openRange.upperBound..<template.endIndex) else { break }
            let name = template[openRange.upperBound..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                result.append((openRange.lowerBound..<closeRange.upperBound, name))
            }
            searchStart = closeRange.upperBound
        }
        return result
    }

    /// Variabelnamnen i mallen, i den ordning de först förekommer, utan dubbletter.
    public var variableNames: [String] {
        var seen = Set<String>()
        return occurrences.map(\.name).filter { seen.insert($0).inserted }
    }

    /// Ersätter varje `{{namn}}`-förekomst med `values[namn]`. Saknade värden
    /// ersätts med tom sträng (renderas alltså inte som `{{namn}}` kvar i
    /// klartext — en halvifylld snippet är fortfarande ett giltigt, om än
    /// ofullständigt, kommando att granska innan det skickas).
    public func rendered(with values: [String: String]) -> String {
        var result = template
        for (range, name) in occurrences.reversed() {
            result.replaceSubrange(range, with: values[name] ?? "")
        }
        return result
    }
}
