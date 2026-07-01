//
// FingerprintQuery.swift
//
// Der überzeugende Moment (Phase 3, #6): auf der Fingerprint-Tabelle zwei
// Aufgaben, die technisch entgegengesetzt sind.
//
//   • Abfrage  — „ich sage genau, was ich will, gib es ohne Müll": harte,
//                kombinierbare Filter (Jahr, Länge, Mix-Art, Energie).
//   • Nachbarn — „zeig mir Verwandtes zu diesem Titel": geordnet nach gleicher
//                Ära, Längenklasse, Mix-Art und ähnlicher Energie.
//
// Reine, cloud-freie Logik: keine KI, kein Netz. Die Energie ist keine eigene
// gespeicherte Achse, sondern relativ zum eigenen Datensatz normalisiert —
// „hohe Energie" heißt hoch *für diese Bibliothek*, ehrlich und ohne fremde
// Skala.
//

import Foundation

// MARK: - Mix-Klasse

/// Grobe Klasse der Mix-Version — die Textvielfalt der Tags auf wenige, für die
/// Empfehlung relevante Kategorien reduziert.
public enum MixClass: String, Sendable, CaseIterable {
    case radioEdit   // kurz fürs Radio: radio, single, edit, airplay, video
    case extended    // lang für den Club: extended, club, maxi, 12"
    case remix       // umgestaltet: remix
    case original    // keine Version im Titel (Album-/Originalfassung)
    case other       // sonstige benannte Version

    /// Ordnet einen (rohen) Versions-Text einer Klasse zu.
    public static func classify(_ version: String?) -> MixClass {
        guard let raw = version?.lowercased(), !raw.isEmpty else { return .original }
        if raw.contains("extended") || raw.contains("club") || raw.contains("maxi") || raw.contains("12\"") {
            return .extended
        }
        if raw.contains("radio") || raw.contains("single") || raw.contains("airplay")
            || raw.contains("video") || raw.contains("edit") {
            return .radioEdit
        }
        if raw.contains("remix") { return .remix }
        return .other
    }
}

extension TrackFingerprint {
    /// Die Mix-Klasse dieses Titels.
    public var mixClass: MixClass { MixClass.classify(mixVersion) }
}

// MARK: - Filter

/// Kombinierbare Abfragefilter. Jedes nicht gesetzte Feld ist kein Filter.
public struct FingerprintFilter: Sendable {
    public var yearRange: ClosedRange<Int>?
    public var durationRange: ClosedRange<Double>?   // Sekunden
    public var mixClass: MixClass?
    public var bpmRange: ClosedRange<Double>?
    public var minEnergy: Double?                    // 0…1, relativ zum Datensatz
    public var maxEnergy: Double?

    public init(
        yearRange: ClosedRange<Int>? = nil,
        durationRange: ClosedRange<Double>? = nil,
        mixClass: MixClass? = nil,
        bpmRange: ClosedRange<Double>? = nil,
        minEnergy: Double? = nil,
        maxEnergy: Double? = nil
    ) {
        self.yearRange = yearRange
        self.durationRange = durationRange
        self.mixClass = mixClass
        self.bpmRange = bpmRange
        self.minEnergy = minEnergy
        self.maxEnergy = maxEnergy
    }
}

/// Ein Nachbar plus die (kleinere = ähnlichere) Distanz zum Ankertitel.
public struct FingerprintNeighbor: Sendable {
    public let track: TrackFingerprint
    public let distance: Double
}

// MARK: - Datensatz

/// Die geladene Fingerprint-Menge plus die daraus abgeleiteten Achsen-Bereiche.
/// Trägt Abfrage und Nachbarsuche; beide teilen dieselbe Normalisierung.
public final class FingerprintDataset {
    public let tracks: [TrackFingerprint]

    private let loudness: MinMax
    private let bpm: MinMax
    private let bass: MinMax
    private let dynamic: MinMax
    private let brightness: MinMax

    public init(tracks: [TrackFingerprint]) {
        self.tracks = tracks
        loudness = MinMax(tracks.map(\.rmsLoudnessDb))
        bpm = MinMax(tracks.compactMap(\.bpm))
        bass = MinMax(tracks.map(\.bassRatio))
        dynamic = MinMax(tracks.map(\.dynamicRangeDb))
        brightness = MinMax(tracks.map(\.spectralBrightnessHz))
    }

    // MARK: Energie

    /// Energie 0…1: laut + schnell + basslastig + wenig Dynamik = treibend.
    /// Alle Anteile relativ zum Datensatz normalisiert und gleich gewichtet.
    public func energy(of track: TrackFingerprint) -> Double {
        let loud = loudness.normalize(track.rmsLoudnessDb)
        let fast = bpm.normalize(track.bpm ?? bpm.min)
        let low = bass.normalize(track.bassRatio)
        let steady = 1 - dynamic.normalize(track.dynamicRangeDb)
        return (loud + fast + low + steady) / 4
    }

    // MARK: Abfrage

    /// Alle Titel, die *alle* gesetzten Filter erfüllen.
    public func query(_ filter: FingerprintFilter) -> [TrackFingerprint] {
        tracks.filter { track in
            if let range = filter.yearRange {
                guard let year = track.year, range.contains(year) else { return false }
            }
            if let range = filter.durationRange, !range.contains(track.durationSeconds) { return false }
            if let mix = filter.mixClass, track.mixClass != mix { return false }
            if let range = filter.bpmRange {
                guard let value = track.bpm, range.contains(value) else { return false }
            }
            if filter.minEnergy != nil || filter.maxEnergy != nil {
                let value = energy(of: track)
                if let min = filter.minEnergy, value < min { return false }
                if let max = filter.maxEnergy, value > max { return false }
            }
            return true
        }
    }

    // MARK: Nachbarn

    /// Die `limit` nächsten Nachbarn zum Anker, aufsteigend nach Distanz. Der
    /// Anker selbst (gleicher Pfad) ist ausgeschlossen.
    public func neighbors(of anchor: TrackFingerprint, limit: Int = 10) -> [FingerprintNeighbor] {
        tracks
            .filter { $0.path != anchor.path }
            .map { FingerprintNeighbor(track: $0, distance: distance(anchor: anchor, to: $0)) }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { $0 }
    }

    /// Gewichtete Distanz: die Ära führt (die Empfehlung soll in der Zeit bleiben),
    /// dann das **Tempo** (mit dem breiten Suchband jetzt verlässlich — der schärfste
    /// Trenner, Dance ~140 vs. Rap ~90) und die einzelnen Klang-Achsen (Dynamik, Bass,
    /// Klangfarbe, Lautheit, jeweils **getrennt**, damit sich stiltrennende Unterschiede
    /// addieren statt sich in einer gemittelten „Energie" auszugleichen), dazu die
    /// **Beat-Klarheit** (Confidence: klarer Four-on-the-Floor vs. komplexer Rhythmus),
    /// zuletzt Mix-Art und Länge. Alles datensatz-relativ normiert und rein akustisch
    /// (tag-unabhängig — Genre-Tags in Compilations sind oft pauschal oder leer).
    private func distance(anchor: TrackFingerprint, to candidate: TrackFingerprint) -> Double {
        var sum = 0.0

        // Ära (Jahr): ±5 Jahre spannen die volle Teil-Distanz auf.
        if let anchorYear = anchor.year, let candidateYear = candidate.year {
            sum += 3.0 * min(1, Double(abs(anchorYear - candidateYear)) / 5.0)
        } else {
            sum += 3.0 * 0.5   // unbekanntes Jahr: mittlere, nicht maximale Strafe
        }

        // Tempo: der schärfste Trenner, sobald der Schätzer den echten Beat findet.
        // Nur wenn beide einen Wert haben — ohne erkannten Beat keine Aussage.
        if let anchorBpm = anchor.bpm, let candidateBpm = candidate.bpm {
            sum += 2.0 * axisDistance(bpm, anchorBpm, candidateBpm)
        }

        // Klang-Charakter: die Achsen, die Stil/Genre am stärksten tragen — Dynamik
        // (Sprach-/Transienten-Struktur vs. durchlaufender Four-on-the-Floor), Bass-Anteil
        // und Klangfarbe. Einzeln gewichtet, damit sie sich addieren.
        sum += 1.5 * axisDistance(dynamic, anchor.dynamicRangeDb, candidate.dynamicRangeDb)
        sum += 1.5 * axisDistance(bass, anchor.bassRatio, candidate.bassRatio)
        sum += 1.5 * axisDistance(brightness, anchor.spectralBrightnessHz, candidate.spectralBrightnessHz)
        // Lautheit: schwächeres, Mastering-abhängiges Signal — zählt mit, aber leichter.
        sum += 1.0 * axisDistance(loudness, anchor.rmsLoudnessDb, candidate.rmsLoudnessDb)

        // Beat-Klarheit: ein sauberer Dance-Beat (hohe Confidence) unterscheidet sich vom
        // rhythmisch komplexen Rap/Rock (niedrige Confidence). Confidence ist bereits 0…1.
        if let anchorConfidence = anchor.bpmConfidence, let candidateConfidence = candidate.bpmConfidence {
            sum += 1.0 * abs(anchorConfidence - candidateConfidence)
        }

        // Mix-Art: gleiche Klasse ist gut, sonst voller Teilbeitrag.
        sum += 1.0 * (candidate.mixClass == anchor.mixClass ? 0 : 1)

        // Länge: 2 Minuten Unterschied spannen die volle Teil-Distanz auf.
        sum += 1.0 * min(1, abs(candidate.durationSeconds - anchor.durationSeconds) / 120.0)

        return sum
    }

    /// Betrag der Differenz einer Achse, auf 0…1 datensatz-relativ normiert.
    private func axisDistance(_ scale: MinMax, _ anchorValue: Double, _ candidateValue: Double) -> Double {
        abs(scale.normalize(anchorValue) - scale.normalize(candidateValue))
    }
}

// MARK: - Hilfsmittel

/// Min/Max einer Achse über den Datensatz, für die 0…1-Normalisierung.
private struct MinMax {
    let min: Double
    let max: Double

    init(_ values: [Double]) {
        min = values.min() ?? 0
        max = values.max() ?? 0
    }

    /// Auf 0…1 skaliert; bei entartetem Bereich (alle gleich) neutral 0,5.
    func normalize(_ value: Double) -> Double {
        guard max > min else { return 0.5 }
        return Swift.max(0, Swift.min(1, (value - min) / (max - min)))
    }
}
