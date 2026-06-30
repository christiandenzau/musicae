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
    public var durationSeconds: Double
    public var bpm: Double?
    public var bpmConfidence: Double?
    public var rmsLoudnessDb: Double
    public var dynamicRangeDb: Double
    public var spectralBrightnessHz: Double
    public var bassRatio: Double
    public var mixVersion: String?
    public var analyzedAt: Date

    public static let databaseTableName = "track_fingerprints"

    /// Spaltennamen in snake_case — wie im Musicae-Schema.
    enum CodingKeys: String, CodingKey {
        case path
        case title
        case durationSeconds = "duration_seconds"
        case bpm
        case bpmConfidence = "bpm_confidence"
        case rmsLoudnessDb = "rms_loudness_db"
        case dynamicRangeDb = "dynamic_range_db"
        case spectralBrightnessHz = "spectral_brightness_hz"
        case bassRatio = "bass_ratio"
        case mixVersion = "mix_version"
        case analyzedAt = "analyzed_at"
    }

    public init(
        path: String,
        title: String?,
        durationSeconds: Double,
        bpm: Double?,
        bpmConfidence: Double?,
        axes: AudioAxes,
        mixVersion: String?,
        analyzedAt: Date
    ) {
        self.path = path
        self.title = title
        self.durationSeconds = durationSeconds
        self.bpm = bpm
        self.bpmConfidence = bpmConfidence
        self.rmsLoudnessDb = axes.rmsLoudnessDb
        self.dynamicRangeDb = axes.dynamicRangeDb
        self.spectralBrightnessHz = axes.spectralBrightnessHz
        self.bassRatio = axes.bassRatio
        self.mixVersion = mixVersion
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

    /// Liest einen Fingerprint nach Pfad (vor allem für Tests/Inspektion).
    public func fingerprint(forPath path: String) throws -> TrackFingerprint? {
        try dbQueue.read { db in
            try TrackFingerprint.fetchOne(db, key: path)
        }
    }
}
