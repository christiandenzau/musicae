//
// LibraryMBIDReader.swift
//
// Woher die Recording-MBIDs der Scheibe kommen (Phase 4, #7). Die verlässliche
// Quelle ist die **Musicae-Bibliotheks-DB**: dort haben Musicae' Metadaten-Leser
// die MBIDs bereits aus jedem Tag-Format (ID3-UFID, iTunes-Freeform,
// Vorbis-Comment) korrekt herausgezogen und im `extended_metadata`-JSON als
// `musicBrainzTrackId` (= Recording-MBID, Schema-Karte §6) abgelegt. Statt das
// fehleranfällige Tag-Parsen zu wiederholen, lesen wir dieses fertige Ergebnis
// **schreibgeschützt** aus.
//
// Praxis: Läuft Musicae, ist die DB im WAL-Modus gesperrt — dann gegen eine
// Kopie (inkl. `-wal`/`-shm`) arbeiten (siehe Schema-Karte §1).
//

import Foundation
import GRDB

/// Ein Titel der Bibliothek mit seiner Recording-MBID — der Anker in den Graphen.
public struct LibraryTrackRef: Sendable, Equatable {
    public let path: String
    public let title: String?
    public let artist: String?
    public let recordingMBID: String

    public init(path: String, title: String?, artist: String?, recordingMBID: String) {
        self.path = path
        self.title = title
        self.artist = artist
        self.recordingMBID = recordingMBID
    }
}

public enum LibraryMBIDReader {
    /// Liest alle Titel mit einer gültigen Recording-MBID aus einer
    /// Musicae-Bibliotheks-DB (schreibgeschützt geöffnet). Titel ohne MBID oder
    /// mit unbrauchbarer MBID werden übersprungen.
    public static func recordingRefs(fromLibraryAt path: String) throws -> [LibraryTrackRef] {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT path, title, artist, extended_metadata FROM tracks WHERE extended_metadata IS NOT NULL"
            )
            var refs: [LibraryTrackRef] = []
            var seen = Set<String>()
            for row in rows {
                guard let path: String = row["path"],
                      let json: String = row["extended_metadata"],
                      let mbid = recordingMBID(fromJSON: json),
                      seen.insert(mbid).inserted else { continue }
                refs.append(LibraryTrackRef(
                    path: path,
                    title: row["title"],
                    artist: row["artist"],
                    recordingMBID: mbid
                ))
            }
            return refs
        }
    }

    /// Zieht die Recording-MBID aus einem `extended_metadata`-JSON. `nil`, wenn
    /// keine da oder keine gültige UUID. Reine Stringlogik, direkt testbar.
    static func recordingMBID(fromJSON json: String) -> String? {
        struct MBIDsOnly: Decodable { let musicBrainzTrackId: String? }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MBIDsOnly.self, from: data),
              let mbid = decoded.musicBrainzTrackId?.trimmingCharacters(in: .whitespaces),
              !mbid.isEmpty,
              UUID(uuidString: mbid) != nil else { return nil }
        return mbid
    }
}
