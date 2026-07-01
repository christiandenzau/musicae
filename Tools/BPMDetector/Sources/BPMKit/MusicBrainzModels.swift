//
// MusicBrainzModels.swift
//
// Die Draht-Modelle (DTOs) der MusicBrainz-Web-API (WS/2, `fmt=json`), Phase 4
// (#7). Bewusst nur die Felder, die der Beziehungsgraph der Testscheibe braucht
// — nicht die ganze API. Getrennt vom Domänenmodell (`RelationGraph.swift`):
// Hier steht das rohe JSON-Format, dort der begehbare Graph. So bleibt das
// Mapping an einer Stelle prüfbar und der Rest der Logik netz- und formatfrei.
//
// Referenz: https://musicbrainz.org/doc/MusicBrainz_API
//   Recording-Lookup  /ws/2/recording/<mbid>?inc=artist-credits+releases+recording-rels+work-rels
//   Release-Lookup     /ws/2/release/<mbid>?inc=labels+release-groups
//

import Foundation

// MARK: - Recording

/// Antwort eines Recording-Lookups. Trägt den Aufnahme-Knoten selbst, die
/// Releases, auf denen sie erscheint, und die Beziehungen (Remix-von, Cover …).
public struct MBRecording: Codable, Sendable {
    public let id: String
    public let title: String?
    public let disambiguation: String?
    /// Verlässliches Jahr der *Aufnahme* (nicht dieses Tonträgers). Format „1993"
    /// oder „1993-09-06" — beides tolerant zu parsen.
    public let firstReleaseDate: String?
    public let artistCredit: [MBArtistCredit]?
    public let releases: [MBRelease]?
    public let relations: [MBRelation]?

    enum CodingKeys: String, CodingKey {
        case id, title, disambiguation
        case firstReleaseDate = "first-release-date"
        case artistCredit = "artist-credit"
        case releases, relations
    }
}

// MARK: - Release

/// Ein Tonträger (die „Maxi", das „Album"). Beim Recording-Lookup nur mit den
/// Basisfeldern gefüllt; das Label und die Release-Gruppe kommen erst über einen
/// gezielten Release-Lookup (`inc=labels+release-groups`).
public struct MBRelease: Codable, Sendable {
    public let id: String
    public let title: String?
    public let date: String?
    public let status: String?
    public let country: String?
    public let labelInfo: [MBLabelInfo]?
    public let releaseGroup: MBReleaseGroup?

    enum CodingKeys: String, CodingKey {
        case id, title, date, status, country
        case labelInfo = "label-info"
        case releaseGroup = "release-group"
    }
}

public struct MBLabelInfo: Codable, Sendable {
    public let catalogNumber: String?
    public let label: MBNamed?

    enum CodingKeys: String, CodingKey {
        case catalogNumber = "catalog-number"
        case label
    }
}

/// Die Release-Gruppe — das „Werk als Veröffentlichung" über alle Auflagen
/// hinweg (das „Album des Jahres", zu dem die Maxi gehört).
public struct MBReleaseGroup: Codable, Sendable {
    public let id: String
    public let title: String?
    public let primaryType: String?
    public let firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case primaryType = "primary-type"
        case firstReleaseDate = "first-release-date"
    }
}

// MARK: - Beziehungen

/// Eine Beziehungskante aus MusicBrainz. Das eingebettete Zielobjekt hängt am
/// `targetType` — für Recording-Beziehungen (Remix, Cover) steht es in
/// `recording`, für Werk-Beziehungen in `work`, usw. Genau eines ist gesetzt.
public struct MBRelation: Codable, Sendable {
    public let type: String?
    /// „forward" oder „backward" — legt fest, wie `type` zu lesen ist (Remix-von
    /// vs. wird-remixt-von). Trägt die ehrliche Richtung der Kante.
    public let direction: String?
    public let targetType: String?
    public let recording: MBRef?
    public let work: MBRef?
    public let release: MBRef?
    public let artist: MBRef?

    enum CodingKeys: String, CodingKey {
        case type, direction
        case targetType = "target-type"
        case recording, work, release, artist
    }

    /// Das eingebettete Zielobjekt, unabhängig von seinem JSON-Schlüssel.
    public var target: MBRef? {
        recording ?? work ?? release ?? artist
    }
}

// MARK: - Kleine Referenzen

/// Eine Entität mit Titel (Recording/Release/Work) — genug für einen Knoten.
public struct MBRef: Codable, Sendable {
    public let id: String
    public let title: String?
    public let disambiguation: String?
    public let firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, disambiguation
        case firstReleaseDate = "first-release-date"
    }
}

/// Eine Entität mit Namen (Künstler/Label) — die Namensform statt Titel.
public struct MBNamed: Codable, Sendable {
    public let id: String?
    public let name: String?
}

public struct MBArtistCredit: Codable, Sendable {
    public let name: String?
    public let joinphrase: String?
    public let artist: MBNamed?
}

extension Array where Element == MBArtistCredit {
    /// Fügt die Credit-Teile zum vollständigen Künstlernamen zusammen
    /// (inkl. der Verbindungswörter wie „ feat. ").
    public var displayName: String? {
        guard !isEmpty else { return nil }
        let joined = reduce(into: "") { result, credit in
            result += credit.name ?? credit.artist?.name ?? ""
            result += credit.joinphrase ?? ""
        }
        let trimmed = joined.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
