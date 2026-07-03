import Foundation

/// Ett synkbart tillstånd: levande värdar + gravstenar (raderade id:n med tid).
/// Detta är vad som skrivs till/läses från en synktransport (iCloud/Git/WebDAV/
/// mapp). Formatet är avsiktligt enkelt och diff-bart.
public struct SyncState: Codable, Sendable, Equatable {
    public var hosts: [Host]
    public var tombstones: [UUID: Date]

    public init(hosts: [Host] = [], tombstones: [UUID: Date] = [:]) {
        self.hosts = hosts
        self.tombstones = tombstones
    }
}

/// Slår ihop två tillstånd deterministiskt utan server. Regler:
/// - Samma värd på båda sidor: nyaste `modifiedAt` vinner (last-write-wins).
/// - Radering (gravsten) vinner om den är minst lika ny som värdens ändring;
///   annars "återupplivas" värden (en nyare redigering slår en äldre radering).
/// - Resultatet är kommutativt och idempotent → säkert att köra upprepat och i
///   valfri ordning mellan enheter.
public enum SyncEngine {
    public static func merge(_ a: SyncState, _ b: SyncState) -> SyncState {
        // Nyaste versionen av varje värd.
        var newestHost: [UUID: Host] = [:]
        for h in a.hosts + b.hosts {
            if let existing = newestHost[h.id] {
                if h.modifiedAt >= existing.modifiedAt { newestHost[h.id] = h }
            } else {
                newestHost[h.id] = h
            }
        }
        // Nyaste gravstenen per id.
        var tomb: [UUID: Date] = [:]
        for (id, t) in a.tombstones { tomb[id] = max(t, tomb[id] ?? .distantPast) }
        for (id, t) in b.tombstones { tomb[id] = max(t, tomb[id] ?? .distantPast) }

        var liveHosts: [Host] = []
        var finalTombstones: [UUID: Date] = [:]
        for id in Set(newestHost.keys).union(tomb.keys) {
            switch (newestHost[id], tomb[id]) {
            case let (host?, deletedAt?):
                if deletedAt >= host.modifiedAt {
                    finalTombstones[id] = deletedAt        // radering vinner
                } else {
                    liveHosts.append(host)                 // nyare redigering återupplivar
                }
            case let (host?, nil):
                liveHosts.append(host)
            case let (nil, deletedAt?):
                finalTombstones[id] = deletedAt
            case (nil, nil):
                break
            }
        }
        return SyncState(
            hosts: liveHosts.sorted { $0.alias.lowercased() < $1.alias.lowercased() },
            tombstones: finalTombstones)
    }
}
