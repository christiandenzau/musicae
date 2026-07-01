import Foundation
import GRDB

/// Die je Titel **berechneten** (nicht getaggten) Audio-Achsen aus `BPMKit`,
/// persistiert in `track_fingerprints` und über `track_id` fest an `tracks`
/// gekoppelt (1:1, `ON DELETE CASCADE`). Bewusst eine eigene Tabelle statt
/// weiterer `tracks`-Spalten: die harten Tag-Fakten (u. a. `tracks.bpm`) bleiben
/// unangetastet, die gerechnete Schicht ist quellenbewusst getrennt und
/// umkehrbar (Ehrlichkeitsgesetz, siehe Schema-Karte §6/§9).
///
/// Der Name grenzt bewusst ab: dies ist **nicht** der externe
/// AcoustID/Chromaprint-Fingerprint (der lebt im `extended_metadata`-JSON),
/// sondern die lokal über Accelerate gerechneten Achsen.
struct ComputedFingerprint: FetchableRecord, PersistableRecord, Equatable, Sendable {
    /// Schlüssel und Fremdschlüssel zugleich: `tracks.id`.
    let trackId: Int64
    /// Nativ geschätztes Tempo. Getrennt vom getaggten `tracks.bpm`, überschreibt
    /// es nie. `nil`, wenn der Schätzer im Eurodance-Band nichts Belastbares fand.
    var calculatedBpm: Double?
    /// Konfidenz des Tempo-Schätzers (0…1), zur ehrlichen Einordnung.
    var bpmConfidence: Double?
    /// Gesamtlautheit als RMS in dBFS (0 dB = Vollausschlag, negativ = leiser).
    var rmsLoudnessDb: Double
    /// Dynamikumfang: Streuung der kurzzeitigen Lautheit (dB). Klein = durchgehend
    /// laut, groß = ruhige und laute Passagen.
    var dynamicRangeDb: Double
    /// Spektrale Helligkeit: energiegewichteter Frequenzschwerpunkt in Hz.
    var spectralBrightnessHz: Double
    /// Bass-Anteil: Anteil der Spektralenergie unterhalb der Bass-Grenze (0…1).
    var bassRatio: Double
    /// Beat-Regelmäßigkeit (0…1) — tag-unabhängige rhythmische Achse (Phase 5b,
    /// #23): wie loopregelmäßig der Rhythmus ist (Dance/Techno hoch, organisches
    /// Schlagzeug niedrig). Optional: leer, bis der Analyzer (v3) den Titel neu
    /// gerechnet hat; zählt bis dahin in der Nachbardistanz neutral.
    var beatRegularity: Double?
    /// Aus dem Titel geparste Mix-/Versionsangabe (z. B. „Extended", „Radio Edit").
    var mixVersion: String?
    /// Grobe Mix-Klasse (`BPMKit.MixClass`-rawValue: extended/radioEdit/remix/
    /// original/other). Denormalisiert aus `mixVersion` über die *eine*
    /// Klassifizierungsquelle `MixClass.classify`, damit die Smart-Playlist-Abfrage
    /// (#16) ohne die prioritätsbehaftete Logik in SQL nachzubauen filtern kann.
    var mixClass: String?
    /// Zeitpunkt der Berechnung.
    var analyzedAt: Date

    static let databaseTableName = "track_fingerprints"
    // Ein erneuter Analyselauf ersetzt die Zeile idempotent.
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace, update: .replace)

    enum Columns {
        static let trackId = Column("track_id")
        static let calculatedBpm = Column("calculated_bpm")
        static let bpmConfidence = Column("bpm_confidence")
        static let rmsLoudnessDb = Column("rms_loudness_db")
        static let dynamicRangeDb = Column("dynamic_range_db")
        static let spectralBrightnessHz = Column("spectral_brightness_hz")
        static let bassRatio = Column("bass_ratio")
        static let beatRegularity = Column("beat_regularity")
        static let mixVersion = Column("mix_version")
        static let mixClass = Column("mix_class")
        static let analyzedAt = Column("analyzed_at")
    }

    init(
        trackId: Int64,
        calculatedBpm: Double?,
        bpmConfidence: Double?,
        rmsLoudnessDb: Double,
        dynamicRangeDb: Double,
        spectralBrightnessHz: Double,
        bassRatio: Double,
        beatRegularity: Double?,
        mixVersion: String?,
        mixClass: String?,
        analyzedAt: Date
    ) {
        self.trackId = trackId
        self.calculatedBpm = calculatedBpm
        self.bpmConfidence = bpmConfidence
        self.rmsLoudnessDb = rmsLoudnessDb
        self.dynamicRangeDb = dynamicRangeDb
        self.spectralBrightnessHz = spectralBrightnessHz
        self.bassRatio = bassRatio
        self.beatRegularity = beatRegularity
        self.mixVersion = mixVersion
        self.mixClass = mixClass
        self.analyzedAt = analyzedAt
    }

    init(row: Row) throws {
        trackId = row[Columns.trackId]
        calculatedBpm = row[Columns.calculatedBpm]
        bpmConfidence = row[Columns.bpmConfidence]
        rmsLoudnessDb = row[Columns.rmsLoudnessDb]
        dynamicRangeDb = row[Columns.dynamicRangeDb]
        spectralBrightnessHz = row[Columns.spectralBrightnessHz]
        bassRatio = row[Columns.bassRatio]
        beatRegularity = row[Columns.beatRegularity]
        mixVersion = row[Columns.mixVersion]
        mixClass = row[Columns.mixClass]
        analyzedAt = row[Columns.analyzedAt]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.trackId] = trackId
        container[Columns.calculatedBpm] = calculatedBpm
        container[Columns.bpmConfidence] = bpmConfidence
        container[Columns.rmsLoudnessDb] = rmsLoudnessDb
        container[Columns.dynamicRangeDb] = dynamicRangeDb
        container[Columns.spectralBrightnessHz] = spectralBrightnessHz
        container[Columns.bassRatio] = bassRatio
        container[Columns.beatRegularity] = beatRegularity
        container[Columns.mixVersion] = mixVersion
        container[Columns.mixClass] = mixClass
        container[Columns.analyzedAt] = analyzedAt
    }
}

// MARK: - Association

extension Track {
    /// The track's computed fingerprint (1:1, keyed on `track_fingerprints.track_id`).
    /// Used as an optional join so smart-playlist rules can filter on the computed axes
    /// while tracks without a fingerprint simply yield NULLs (never a false match).
    static let computedFingerprint = hasOne(ComputedFingerprint.self, using: ForeignKey(["track_id"]))
}
