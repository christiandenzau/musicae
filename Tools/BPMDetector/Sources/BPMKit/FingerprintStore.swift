//
// FingerprintStore.swift
//
// Persistiert je Track eine Fingerprint-Zeile über GRDB — dieselbe
// Persistenzschicht wie die Musicae-App. Bewusst eine eigene, separate Tabelle
// (`track_fingerprints`) in einer eigenen Datei: kein Eingriff in die
// bestehenden Musicae-Tabellen, das Schema bleibt sauber und umkehrbar. Der
// Schlüssel ist der Dateipfad und deckt sich mit `tracks.path` in Musicae,
// sodass die Achsen später verlustfrei dorthin joinbar (oder migrierbar) sind.
//

import Foundation
import GRDB

/// Der je Track einmal berechnete, persistierte Fingerprint (erste Fassung):
/// die harte Dauer, das Tempo und die leichten Achsen, plus die aus dem Titel
/// geparste Mix-Version.
public struct TrackFingerprint: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var path: String
    public var title: String?
    // Harte Fakten aus den Tags — tragen die Abfrage in #6 (Jahr, Anzeige).
    public var artist: String?
    public var album: String?
    public var year: Int?
    public var durationSeconds: Double
    public var bpm: Double?
    public var bpmConfidence: Double?
    public var rmsLoudnessDb: Double
    public var dynamicRangeDb: Double
    public var spectralBrightnessHz: Double
    public var bassRatio: Double
    /// Beat-Regelmäßigkeit (0…1) — tag-unabhängige rhythmische Achse (Phase 5b,
    /// #23): wie loopregelmäßig der Rhythmus ist (Dance/Techno hoch, organisches
    /// Schlagzeug niedrig). Optional: ältere Fingerprints ohne diese Achse zählen
    /// in der Distanz neutral.
    public var beatRegularity: Double?
    public var mixVersion: String?
    /// Getaggtes Genre (roh, denormalisiert aus `tracks.genre`). **Transient:**
    /// bewusst nicht in `CodingKeys` — wird nicht in `track_fingerprints`
    /// persistiert, sondern in der App beim Join geladen und trägt die weiche
    /// Genre-Familien-Achse (Phase 5b, `GenreFamily`). Keine Re-Analyse nötig,
    /// das Tag steht schon in der DB; das Fingerprint-Tool lässt es leer.
    public var genre: String? = nil
    /// Künstler-MBID (roh, denormalisiert aus `extended_metadata`). **Transient:**
    /// wie `genre` nicht in `CodingKeys` — in der App beim Join geladen, trägt die
    /// Künstler-Ebene der Genre-Reparatur (#32): die weiche Genre-Familie leer
    /// getaggter Titel wird aus der Mehrheit ihres Künstlers gefüllt. Fehlt die
    /// MBID, dient der Künstlername als Ersatzschlüssel.
    public var artistId: String? = nil
    public var analyzedAt: Date

    public static let databaseTableName = "track_fingerprints"

    /// Spaltennamen in snake_case — wie im Musicae-Schema.
    enum CodingKeys: String, CodingKey {
        case path
        case title
        case artist
        case album
        case year
        case durationSeconds = "duration_seconds"
        case bpm
        case bpmConfidence = "bpm_confidence"
        case rmsLoudnessDb = "rms_loudness_db"
        case dynamicRangeDb = "dynamic_range_db"
        case spectralBrightnessHz = "spectral_brightness_hz"
        case bassRatio = "bass_ratio"
        case beatRegularity = "beat_regularity"
        case mixVersion = "mix_version"
        case analyzedAt = "analyzed_at"
    }

    public init(
        path: String,
        title: String?,
        artist: String?,
        album: String?,
        year: Int?,
        durationSeconds: Double,
        bpm: Double?,
        bpmConfidence: Double?,
        axes: AudioAxes,
        beatRegularity: Double? = nil,
        mixVersion: String?,
        genre: String? = nil,
        artistId: String? = nil,
        analyzedAt: Date
    ) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.durationSeconds = durationSeconds
        self.bpm = bpm
        self.bpmConfidence = bpmConfidence
        self.rmsLoudnessDb = axes.rmsLoudnessDb
        self.dynamicRangeDb = axes.dynamicRangeDb
        self.spectralBrightnessHz = axes.spectralBrightnessHz
        self.bassRatio = axes.bassRatio
        self.beatRegularity = beatRegularity
        self.mixVersion = mixVersion
        self.genre = genre
        self.artistId = artistId
        self.analyzedAt = analyzedAt
    }
}

/// Öffnet/erstellt die Fingerprint-Datenbank und schreibt Zeilen idempotent
/// (eine Zeile pro Dateipfad; ein erneuter Lauf überschreibt).
public final class FingerprintStore {
    private let dbQueue: DatabaseQueue

    /// - Parameter path: Pfad der SQLite-Datei. Wird angelegt, falls nicht vorhanden.
    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_track_fingerprints") { db in
            try db.create(table: TrackFingerprint.databaseTableName, ifNotExists: true) { t in
                t.column("path", .text).primaryKey()
                t.column("title", .text)
                t.column("duration_seconds", .double).notNull()
                t.column("bpm", .double)
                t.column("bpm_confidence", .double)
                t.column("rms_loudness_db", .double).notNull()
                t.column("dynamic_range_db", .double).notNull()
                t.column("spectral_brightness_hz", .double).notNull()
                t.column("bass_ratio", .double).notNull()
                t.column("mix_version", .text)
                t.column("analyzed_at", .datetime).notNull()
            }
        }
        // #6 braucht harte Fakten für die Abfrage; additiv, damit ältere
        // Fingerprint-Dateien ohne Datenverlust nachziehen.
        migrator.registerMigration("v2_add_facts") { db in
            try db.alter(table: TrackFingerprint.databaseTableName) { t in
                t.add(column: "artist", .text)
                t.add(column: "album", .text)
                t.add(column: "year", .integer)
            }
        }
        // #23: die Beat-Regelmäßigkeit; additiv und nullable, sodass ältere
        // Fingerprint-Dateien ohne Datenverlust nachziehen — der Wert bleibt leer,
        // bis neu analysiert wird.
        migrator.registerMigration("v3_add_beat_regularity") { db in
            try db.alter(table: TrackFingerprint.databaseTableName) { t in
                t.add(column: "beat_regularity", .double)
            }
        }
        return migrator
    }

    /// Schreibt einen Fingerprint; eine bestehende Zeile gleichen Pfads wird ersetzt.
    public func save(_ fingerprint: TrackFingerprint) throws {
        try dbQueue.write { db in
            try fingerprint.insert(db, onConflict: .replace)
        }
    }

    /// Anzahl gespeicherter Fingerprints.
    public func count() throws -> Int {
        try dbQueue.read { db in
            try TrackFingerprint.fetchCount(db)
        }
    }

    /// Alle Fingerprints (für Abfrage und Nachbarsuche in-memory — bei einer
    /// persönlichen Bibliothek problemlos, spart einen SQL-Query je Achse).
    public func allFingerprints() throws -> [TrackFingerprint] {
        try dbQueue.read { db in
            try TrackFingerprint.order(Column("path")).fetchAll(db)
        }
    }

    /// Liest einen Fingerprint nach Pfad (vor allem für Tests/Inspektion).
    public func fingerprint(forPath path: String) throws -> TrackFingerprint? {
        try dbQueue.read { db in
            try TrackFingerprint.fetchOne(db, key: path)
        }
    }
}
