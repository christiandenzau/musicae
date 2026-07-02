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
    private let beatRegularity: MinMax
    /// Genre-Familie je Künstler aus dem Mehrheitsvotum (#32) — füllt leere
    /// Track-Tags. Aus dem Datensatz abgeleitet, siehe `majorityArtistFamilies`.
    private let artistFamily: [String: GenreFamily]

    public init(tracks: [TrackFingerprint]) {
        self.tracks = tracks
        loudness = MinMax(tracks.map(\.rmsLoudnessDb))
        bpm = MinMax(tracks.compactMap(\.bpm))
        bass = MinMax(tracks.map(\.bassRatio))
        dynamic = MinMax(tracks.map(\.dynamicRangeDb))
        brightness = MinMax(tracks.map(\.spectralBrightnessHz))
        beatRegularity = MinMax(tracks.compactMap(\.beatRegularity))
        artistFamily = Self.majorityArtistFamilies(tracks: tracks)
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

    /// Die nächsten Nachbarn zum Anker, aufsteigend nach Distanz. Der Anker selbst
    /// (gleicher Pfad) ist ausgeschlossen.
    ///
    /// - Parameter maxDistance: Ähnlichkeits-Cutoff. Titel jenseits dieser Distanz gelten
    ///   nicht mehr als verwandt und werden weggelassen — die Liste füllt **nicht** auf
    ///   `limit` auf, wenn es nicht genug wirklich nahe Nachbarn gibt (Ehrlichkeitsgesetz:
    ///   lieber wenige passende als viele mit Füllsel). Default `.infinity` = kein Cutoff.
    /// - Parameter mutualK: **Hubness-Korrektur** (#31). Ein Kandidat zählt nur, wenn der
    ///   Anker auch unter *seinen* `mutualK` nächsten liegt — **gegenseitige** Nähe. Das
    ///   zieht „Hubs" aus dichten Regionen (Dance) heraus, die sonst in fast jeder Liste
    ///   auftauchen, ohne den Anker wirklich zu treffen. Bei kleinen Mengen (weniger als
    ///   `mutualK` andere Titel) ist die Bedingung stets erfüllt, ändert also nichts.
    public func neighbors(
        of anchor: TrackFingerprint,
        limit: Int = 10,
        maxDistance: Double = .infinity,
        mutualK: Int = 25
    ) -> [FingerprintNeighbor] {
        let ranked = tracks
            .filter { $0.path != anchor.path }
            .map { FingerprintNeighbor(track: $0, distance: distance(anchor: anchor, to: $0)) }
            .filter { $0.distance <= maxDistance }
            .sorted { $0.distance < $1.distance }

        var result: [FingerprintNeighbor] = []
        result.reserveCapacity(limit)
        for neighbor in ranked where isAnchor(anchor, amongNearest: mutualK, of: neighbor.track) {
            result.append(neighbor)
            if result.count >= limit { break }
        }
        return result
    }

    /// Ob `anchor` unter den `k` nächsten Nachbarn von `candidate` liegt. Zählt die
    /// Titel, die `candidate` näher sind als `anchor`, und bricht ab, sobald `k`
    /// erreicht sind — für einen Hub (der schnell `k` nähere hat) also früh. Nutzt die
    /// Symmetrie der Distanz, sodass kein zweiter Datensatz nötig ist.
    private func isAnchor(_ anchor: TrackFingerprint, amongNearest k: Int, of candidate: TrackFingerprint) -> Bool {
        guard k > 0 else { return false }
        let anchorDistance = distance(anchor: candidate, to: anchor)
        var closer = 0
        for track in tracks where track.path != candidate.path && track.path != anchor.path {
            if distance(anchor: candidate, to: track) < anchorDistance {
                closer += 1
                if closer >= k { return false }
            }
        }
        return true
    }

    // MARK: Genre-Familie (Künstler-Ebene, #32)

    /// Die für die Distanz maßgebliche Genre-Familie. Das **Track-eigene** Tag
    /// führt (ein echtes Signal für genau diesen Titel); fehlt es, füllt die
    /// **Künstler-Mehrheit** die Lücke. So landen leer getaggte Titel bekannter
    /// Acts (Real McCoy & Co.) in ihrer Familie, ohne korrekt getaggte Titel zu
    /// überstimmen — an der Testscheibe der Unterschied zwischen „Real McCoy in
    /// 9 Pop-Nachbarschaften" und „0". Neutral (`nil`), wenn beides fehlt.
    private func resolvedFamily(_ track: TrackFingerprint) -> GenreFamily? {
        if let own = track.genreFamily { return own }
        guard let key = track.artistKey else { return nil }
        return artistFamily[key]
    }

    /// Genre-Familie je Künstler aus dem **Mehrheitsvotum** seiner getaggten
    /// Titel (#32). Stil ist in dieser Ära eine Künstler-Eigenschaft; leere oder
    /// falsche Compilation-Tags einzelner Titel füllt so die Mehrheit des
    /// Künstlers. Nur eine **echte** Mehrheit (> 50 % der getaggten Vorkommen)
    /// zählt; bei Widerspruch bleibt der Künstler neutral (fehlt im Ergebnis,
    /// Ehrlichkeitsgesetz). Aggregiert über `artistKey` (Künstler-MBID, sonst
    /// Name), sodass Namensvarianten zusammenfallen.
    private static func majorityArtistFamilies(tracks: [TrackFingerprint]) -> [String: GenreFamily] {
        var tally: [String: [GenreFamily: Int]] = [:]
        for track in tracks {
            guard let key = track.artistKey, let family = track.genreFamily else { continue }
            tally[key, default: [:]][family, default: 0] += 1
        }
        var result: [String: GenreFamily] = [:]
        for (key, votes) in tally {
            let total = votes.values.reduce(0, +)
            // Deterministische Mehrheit: meiste Stimmen, bei Gleichstand die in der
            // Familien-Reihenfolge frühere (dance vor pop — wie in `classify`).
            guard let winner = votes.max(by: { lhs, rhs in
                lhs.value != rhs.value
                    ? lhs.value < rhs.value
                    : familyRank(lhs.key) > familyRank(rhs.key)
            }) else { continue }
            if Double(winner.value) / Double(total) > minArtistGenreConfidence {
                result[key] = winner.key
            }
        }
        return result
    }

    /// Rang in der Familien-Prioritätsreihenfolge — für den deterministischen
    /// Gleichstand-Bruch beim Mehrheitsvotum.
    private static func familyRank(_ family: GenreFamily) -> Int {
        GenreFamily.allCases.firstIndex(of: family) ?? GenreFamily.allCases.count
    }

    /// Schwelle der Künstler-Mehrheit: **mehr als die Hälfte** der getaggten
    /// Vorkommen müssen dieselbe Familie tragen, sonst bleibt der Künstler neutral.
    /// An der Testscheibe kalibriert — darüber kein zusätzlicher Gewinn, darunter
    /// wachsende Fehlzuordnung; > 0,5 ist die natürliche „echte Mehrheit"-Grenze.
    private static let minArtistGenreConfidence = 0.5

    /// Gewichtete Distanz: die Ära führt (die Empfehlung soll in der Zeit bleiben),
    /// dann das **Tempo** (der schärfste Trenner, Dance ~140 vs. Rap ~90 — jetzt mit der
    /// BPM-Confidence gewichtet, #30, damit ein unsicher gemessener Beat nicht falsch
    /// zieht) und die einzelnen Klang-Achsen (Dynamik, Bass,
    /// Klangfarbe, Lautheit, jeweils **getrennt**, damit sich stiltrennende Unterschiede
    /// addieren statt sich in einer gemittelten „Energie" auszugleichen), dazu die
    /// **Beat-Regelmäßigkeit** (#23 — der tag-unabhängige rhythmische Trenner, der
    /// loopregelmäßiges Dance/Techno vom variabel-organischen Rock scheidet) und die
    /// **Beat-Klarheit** (Confidence: klarer Four-on-the-Floor vs. komplexer Rhythmus),
    /// dann Mix-Art und Länge, zuletzt die **Genre-Familie** als bewusst *weiches*
    /// Tag-Signal (Phase 5b). Die akustischen Achsen sind datensatz-relativ normiert
    /// und tag-unabhängig; die Genre-Familie kommt als grobe Neigung hinzu und zählt
    /// **neutral**, wo das Tag fehlt oder uneindeutig ist (Genre-Tags in Compilations
    /// sind oft pauschal oder leer — darum weich und nie führend).
    private func distance(anchor: TrackFingerprint, to candidate: TrackFingerprint) -> Double {
        var sum = 0.0

        // Ära (Jahr): ±5 Jahre spannen die volle Teil-Distanz auf.
        if let anchorYear = anchor.year, let candidateYear = candidate.year {
            sum += 3.0 * min(1, Double(abs(anchorYear - candidateYear)) / 5.0)
        } else {
            sum += 3.0 * 0.5   // unbekanntes Jahr: mittlere, nicht maximale Strafe
        }

        // Tempo: der schärfste Trenner, sobald der Schätzer den echten Beat findet —
        // aber nur so weit, wie er dem Wert traut. Der Beitrag skaliert mit der
        // kleineren der beiden BPM-Confidences: ein unsicher gemessenes Tempo (etwa
        // der Doppeltempo-Fehler bei sample-basiertem HipHop) erzeugt so weder falsche
        // Nähe noch falsche Ferne, sondern zählt anteilig neutral (#30, Ehrlichkeits-
        // gesetz). Nur wenn beide einen Wert haben — ohne erkannten Beat keine Aussage.
        if let anchorBpm = anchor.bpm, let candidateBpm = candidate.bpm {
            let tempoTrust = min(anchor.bpmConfidence ?? 1, candidate.bpmConfidence ?? 1)
            sum += 2.0 * tempoTrust * axisDistance(bpm, anchorBpm, candidateBpm)
        }

        // Klang-Charakter: die Achsen, die Stil/Genre am stärksten tragen — Dynamik
        // (Sprach-/Transienten-Struktur vs. durchlaufender Four-on-the-Floor), Bass-Anteil
        // und Klangfarbe. Einzeln gewichtet, damit sie sich addieren.
        sum += 1.5 * axisDistance(dynamic, anchor.dynamicRangeDb, candidate.dynamicRangeDb)
        sum += 1.5 * axisDistance(bass, anchor.bassRatio, candidate.bassRatio)
        sum += 1.5 * axisDistance(brightness, anchor.spectralBrightnessHz, candidate.spectralBrightnessHz)
        // Lautheit: schwächeres, Mastering-abhängiges Signal — zählt mit, aber leichter.
        sum += 1.0 * axisDistance(loudness, anchor.rmsLoudnessDb, candidate.rmsLoudnessDb)

        // Beat-Regelmäßigkeit (Phase 5b, #23), tag-unabhängig: der stärkste
        // rhythmische Trenner zwischen loopregelmäßigem Dance/Techno und dem
        // variabel-organischen Schlagzeug von Rock/Pop — dort, wo Klangfarbe und
        // Tempo sich noch gleichen. An der Testscheibe der beste akustische Filter
        // (echte Techno-Fremdkörper 11→3). Stark gewichtet, aber nur wenn beide
        // Titel den Wert haben; sonst (noch nicht neu analysiert) neutral.
        if let anchorBeat = anchor.beatRegularity, let candidateBeat = candidate.beatRegularity {
            sum += 3.0 * axisDistance(beatRegularity, anchorBeat, candidateBeat)
        }

        // Beat-Klarheit: ein sauberer Dance-Beat (hohe Confidence) unterscheidet sich vom
        // rhythmisch komplexen Rap/Rock (niedrige Confidence). Confidence ist bereits 0…1.
        if let anchorConfidence = anchor.bpmConfidence, let candidateConfidence = candidate.bpmConfidence {
            sum += 1.0 * abs(anchorConfidence - candidateConfidence)
        }

        // Mix-Art: gleiche Klasse ist gut, sonst voller Teilbeitrag.
        sum += 1.0 * (candidate.mixClass == anchor.mixClass ? 0 : 1)

        // Länge: 2 Minuten Unterschied spannen die volle Teil-Distanz auf.
        sum += 1.0 * min(1, abs(candidate.durationSeconds - anchor.durationSeconds) / 120.0)

        // Genre-Familie: eine weiche Neigung (Phase 5b). Gleiche Familie kein
        // Beitrag, andere Familie voller Gewichtsbeitrag — der Trenner gegen den
        // Tag-Fremdkörper (der Dance-Titel in einer Pop/Rock-Nachbarschaft). Die
        // Familie ist künstlerweise repariert (#32): fehlt das Track-Tag, füllt sie
        // die Mehrheit des Künstlers, sodass leer getaggte Real-McCoy-Titel & Co.
        // aus Pop-Nachbarschaften fallen. Fehlt sie bei einem der beiden oder ist
        // sie „Unknown"/uneindeutig, zählt sie neutral: eine Neigung, kein Urteil.
        if let anchorFamily = resolvedFamily(anchor), let candidateFamily = resolvedFamily(candidate) {
            sum += 2.0 * (candidateFamily == anchorFamily ? 0 : 1)
        }

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
