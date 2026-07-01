//
// FingerprintQueryTests.swift
//
// Prüft Abfrage und Nachbarsuche (#6) gegen einen synthetischen Datensatz —
// keine echte DB, keine Audiodateien nötig. Die Logik ist rein.
//

import XCTest
@testable import BPMKit

final class FingerprintQueryTests: XCTestCase {
    // Baut einen Fingerprint mit gezielten Achsen-Werten.
    private func makeFingerprint(
        _ path: String,
        year: Int?,
        duration: Double,
        mix: String?,
        loudness: Double = -12,
        bpm: Double? = 130,
        bass: Double = 0.3,
        dynamic: Double = 6,
        brightness: Double = 1200,
        confidence: Double? = nil,
        genre: String? = nil
    ) -> TrackFingerprint {
        TrackFingerprint(
            path: path,
            title: path,
            artist: "Künstler",
            album: "Album",
            year: year,
            durationSeconds: duration,
            bpm: bpm,
            bpmConfidence: confidence ?? (bpm == nil ? nil : 0.8),
            axes: AudioAxes(rmsLoudnessDb: loudness, dynamicRangeDb: dynamic, spectralBrightnessHz: brightness, bassRatio: bass),
            mixVersion: mix,
            genre: genre,
            analyzedAt: Date()
        )
    }

    // MARK: - Mix-Klasse

    func testMixClassClassification() {
        XCTAssertEqual(MixClass.classify("Extended Mix"), .extended)
        XCTAssertEqual(MixClass.classify("Club Mix"), .extended)
        XCTAssertEqual(MixClass.classify("Radio Edit"), .radioEdit)
        XCTAssertEqual(MixClass.classify("single version"), .radioEdit)
        XCTAssertEqual(MixClass.classify("D.O.N.S. Remix"), .remix)
        XCTAssertEqual(MixClass.classify(nil), .original)
        XCTAssertEqual(MixClass.classify(""), .original)
    }

    // MARK: - Genre-Familie

    func testGenreFamilyClassification() {
        // Dance & seine Spielarten — der eigentliche Trenner.
        XCTAssertEqual(GenreFamily.classify("Dance"), .dance)
        XCTAssertEqual(GenreFamily.classify("Eurodance"), .dance)
        XCTAssertEqual(GenreFamily.classify("Euro House"), .dance)
        XCTAssertEqual(GenreFamily.classify("Electronic"), .dance)
        XCTAssertEqual(GenreFamily.classify("Electrónica,Música,Dance,Trance,House,Techno"), .dance)
        XCTAssertEqual(GenreFamily.classify("Happy Hardcore"), .dance)
        // Pop, Rock, HipHop, Schlager, Klassik.
        XCTAssertEqual(GenreFamily.classify("Pop"), .pop)
        XCTAssertEqual(GenreFamily.classify("Rock"), .rock)
        XCTAssertEqual(GenreFamily.classify("Hip Hop"), .hiphop)
        XCTAssertEqual(GenreFamily.classify("Schlager"), .schlager)
        XCTAssertEqual(GenreFamily.classify("Classical"), .classical)
        // Gemischte Tags: die geordnete Priorität entscheidet. „Pop/Rock" ist
        // Gitarrenmusik → rock (vor pop); „Dance, Rock, Electrónica" ist
        // U96-Techno → dance (steht zuerst, der schärfste Marker).
        XCTAssertEqual(GenreFamily.classify("Pop/Rock*"), .rock)
        XCTAssertEqual(GenreFamily.classify("Dance,Música,Rock,Electrónica"), .dance)
        // Leer / „Unknown" / uneindeutig → keine Familie, neutral.
        XCTAssertNil(GenreFamily.classify(nil))
        XCTAssertNil(GenreFamily.classify(""))
        XCTAssertNil(GenreFamily.classify("Unknown Genre"))
        XCTAssertNil(GenreFamily.classify("Género desconocido"))
    }

    // MARK: - Abfrage

    private var sampleDataset: FingerprintDataset {
        FingerprintDataset(tracks: [
            makeFingerprint("a", year: 1993, duration: 230, mix: "Radio Edit"),
            makeFingerprint("b", year: 1995, duration: 360, mix: "Extended Mix"),
            makeFingerprint("c", year: 1996, duration: 420, mix: "Club Mix"),
            makeFingerprint("d", year: 1999, duration: 200, mix: nil),
            makeFingerprint("e", year: 1995, duration: 500, mix: "Extended Mix")
        ])
    }

    func testQueryYearRange() {
        let hits = sampleDataset.query(FingerprintFilter(yearRange: 1994...1996))
        XCTAssertEqual(Set(hits.map(\.path)), ["b", "c", "e"])
    }

    func testQueryDurationRange() {
        // 5–8 Minuten = 300–480 s.
        let hits = sampleDataset.query(FingerprintFilter(durationRange: 300...480))
        XCTAssertEqual(Set(hits.map(\.path)), ["b", "c"])
    }

    func testQueryMixClass() {
        let hits = sampleDataset.query(FingerprintFilter(mixClass: .extended))
        XCTAssertEqual(Set(hits.map(\.path)), ["b", "c", "e"]) // Club zählt als extended
    }

    func testQueryCombined() {
        // Eurodance 1995–1996, nur Extended, 5–8 min.
        let hits = sampleDataset.query(FingerprintFilter(
            yearRange: 1995...1996,
            durationRange: 300...480,
            mixClass: .extended
        ))
        XCTAssertEqual(Set(hits.map(\.path)), ["b", "c"])
    }

    func testEmptyFilterReturnsAll() {
        XCTAssertEqual(sampleDataset.query(FingerprintFilter()).count, 5)
    }

    // MARK: - Energie

    func testEnergyReflectsAxes() {
        let dataset = FingerprintDataset(tracks: [
            makeFingerprint("quiet", year: 1995, duration: 300, mix: nil, loudness: -22, bpm: 118, bass: 0.12, dynamic: 10),
            makeFingerprint("loud", year: 1995, duration: 300, mix: nil, loudness: -9, bpm: 150, bass: 0.5, dynamic: 3)
        ])
        let quiet = dataset.tracks.first { $0.path == "quiet" }!
        let loud = dataset.tracks.first { $0.path == "loud" }!
        XCTAssertGreaterThan(dataset.energy(of: loud), dataset.energy(of: quiet))
    }

    // MARK: - Nachbarn

    private func neighborDataset() -> (FingerprintDataset, anchor: TrackFingerprint) {
        let anchor = makeFingerprint("anchor", year: 1995, duration: 300, mix: "Extended Mix", loudness: -10, bpm: 140, bass: 0.4, dynamic: 4)
        let dataset = FingerprintDataset(tracks: [
            anchor,
            makeFingerprint("near", year: 1995, duration: 310, mix: "Club Mix", loudness: -11, bpm: 138, bass: 0.38, dynamic: 4.5),
            makeFingerprint("farYear", year: 1985, duration: 300, mix: "Extended Mix", loudness: -10, bpm: 140, bass: 0.4, dynamic: 4),
            makeFingerprint("farMix", year: 1995, duration: 300, mix: "Radio Edit", loudness: -10, bpm: 140, bass: 0.4, dynamic: 4),
            makeFingerprint("farEnergy", year: 1995, duration: 300, mix: "Extended Mix", loudness: -22, bpm: 118, bass: 0.15, dynamic: 9)
        ])
        return (dataset, anchor)
    }

    func testNearestNeighborIsSameEraMixAndEnergy() {
        let (dataset, anchor) = neighborDataset()
        let neighbors = dataset.neighbors(of: anchor, limit: 10)
        XCTAssertEqual(neighbors.first?.track.path, "near")
    }

    func testNeighborsExcludeAnchor() {
        let (dataset, anchor) = neighborDataset()
        let neighbors = dataset.neighbors(of: anchor, limit: 10)
        XCTAssertFalse(neighbors.contains { $0.track.path == "anchor" })
    }

    func testNeighborsRespectLimitAndOrder() {
        let (dataset, anchor) = neighborDataset()
        let neighbors = dataset.neighbors(of: anchor, limit: 2)
        XCTAssertEqual(neighbors.count, 2)
        // Aufsteigende Distanz.
        XCTAssertLessThanOrEqual(neighbors[0].distance, neighbors[1].distance)
    }

    func testNeighborsRespectMaxDistanceCutoff() {
        // Der Cutoff darf die Liste nicht auf `limit` auffüllen: ein Außenseiter bekommt
        // lieber wenige passende Nachbarn als viele mit Füllsel (Ehrlichkeitsgesetz).
        let (dataset, anchor) = neighborDataset()
        let all = dataset.neighbors(of: anchor, limit: 10)
        XCTAssertGreaterThan(all.count, 1)
        // Cutoff knapp unter dem entferntesten Nachbarn → mindestens dieser fällt weg.
        let cutoff = all.last!.distance - 0.001
        let capped = dataset.neighbors(of: anchor, limit: 10, maxDistance: cutoff)
        XCTAssertLessThan(capped.count, all.count, "Cutoff muss den entferntesten Nachbarn ausschließen")
        XCTAssertTrue(capped.allSatisfy { $0.distance <= cutoff }, "Kein Nachbar jenseits des Cutoffs")
        XCTAssertEqual(capped.first?.track.path, all.first?.track.path, "Der nächste Nachbar bleibt")
    }

    func testNeighborsPreferSimilarBrightness() {
        // Anker und beide Kandidaten sind in Ära, Energie, Mix und Länge identisch —
        // sie unterscheiden sich nur in der Klangfarbe (spektrale Helligkeit). Der
        // klanglich nähere Titel muss vor dem dunkleren liegen. Genau der Fall, der
        // hellen Synth-Dance vom dunkleren, sprachlastigen Material trennt, ohne sich
        // auf Genre-Tags zu verlassen.
        let anchor = makeFingerprint("anchor", year: 1996, duration: 300, mix: "Extended Mix", brightness: 1400)
        let dataset = FingerprintDataset(tracks: [
            anchor,
            makeFingerprint("sameColour", year: 1996, duration: 300, mix: "Extended Mix", brightness: 1400),
            makeFingerprint("darker", year: 1996, duration: 300, mix: "Extended Mix", brightness: 600)
        ])
        let neighbors = dataset.neighbors(of: anchor, limit: 10)
        XCTAssertEqual(neighbors.first?.track.path, "sameColour")
        let sameDistance = neighbors.first { $0.track.path == "sameColour" }?.distance ?? .infinity
        let darkerDistance = neighbors.first { $0.track.path == "darker" }?.distance ?? .infinity
        XCTAssertLessThan(sameDistance, darkerDistance)
    }

    func testNeighborsSeparateOnCombinedTimbre() {
        // Zwei Kandidaten, gleich in Ära, Mix und Länge. „twin" teilt Bass, Dynamik und
        // Helligkeit mit dem Anker; „intruder" weicht in allen dreien ab — ein Genre-
        // Fremdkörper wie Rap/Rock in einer Dance-Compilation, den die gemittelte Energie
        // durchgehen ließe. Weil die Klang-Achsen einzeln zählen, addiert sich seine
        // Distanz und er landet klar hinter dem klanglichen Zwilling.
        let anchor = makeFingerprint("anchor", year: 1996, duration: 300, mix: "Extended Mix", bass: 0.6, dynamic: 3, brightness: 1500)
        let dataset = FingerprintDataset(tracks: [
            anchor,
            makeFingerprint("twin", year: 1996, duration: 300, mix: "Extended Mix", bass: 0.58, dynamic: 3.2, brightness: 1500),
            makeFingerprint("intruder", year: 1996, duration: 300, mix: "Extended Mix", bass: 0.2, dynamic: 9, brightness: 700)
        ])
        let neighbors = dataset.neighbors(of: anchor, limit: 10)
        XCTAssertEqual(neighbors.first?.track.path, "twin")
        let twinDistance = neighbors.first { $0.track.path == "twin" }?.distance ?? .infinity
        let intruderDistance = neighbors.first { $0.track.path == "intruder" }?.distance ?? .infinity
        XCTAssertLessThan(twinDistance, intruderDistance)
    }

    func testNeighborsSeparateOnTempoAndConfidence() {
        // Zwei Kandidaten, gleich in Ära, Klang, Mix und Länge. „danceTwin" teilt Tempo
        // und Beat-Klarheit mit dem Dance-Anker; „slowRap" ist deutlich langsamer und hat
        // einen unklaren Beat (niedrige Confidence) — genau das Rödelheim-Muster (echt
        // ~97 BPM, 28 % Confidence gegen „No Limit" ~140, 84 %). Tempo- und Confidence-
        // Achse schieben ihn klar hinter den Dance-Zwilling.
        let anchor = makeFingerprint("anchor", year: 1996, duration: 300, mix: "Extended Mix", bpm: 140, confidence: 0.85)
        let dataset = FingerprintDataset(tracks: [
            anchor,
            makeFingerprint("danceTwin", year: 1996, duration: 300, mix: "Extended Mix", bpm: 138, confidence: 0.82),
            makeFingerprint("slowRap", year: 1996, duration: 300, mix: "Extended Mix", bpm: 97, confidence: 0.28)
        ])
        let neighbors = dataset.neighbors(of: anchor, limit: 10)
        XCTAssertEqual(neighbors.first?.track.path, "danceTwin")
        let twinDistance = neighbors.first { $0.track.path == "danceTwin" }?.distance ?? .infinity
        let rapDistance = neighbors.first { $0.track.path == "slowRap" }?.distance ?? .infinity
        XCTAssertLessThan(twinDistance, rapDistance)
    }

    func testNeighborsPenalizeForeignGenreFamily() {
        // Der belegte Spin-Doctors-Fall, synthetisch: Anker ist Pop; ein Pop-
        // Zwilling und ein Dance-Fremdkörper sind in Ära, Tempo, Klang, Mix und
        // Länge identisch — nur die Genre-Familie trennt sie. Die weiche Achse muss
        // den Fremdkörper hinter den echten Nachbarn schieben, und zwar um genau das
        // Achsengewicht 2 (weil sonst alles gleich ist).
        let anchor = makeFingerprint("anchor", year: 1993, duration: 240, mix: nil, genre: "Pop")
        let dataset = FingerprintDataset(tracks: [
            anchor,
            makeFingerprint("popTwin", year: 1993, duration: 240, mix: nil, genre: "Pop"),
            makeFingerprint("danceIntruder", year: 1993, duration: 240, mix: nil, genre: "Eurodance")
        ])
        let neighbors = dataset.neighbors(of: anchor, limit: 10)
        XCTAssertEqual(neighbors.first?.track.path, "popTwin")
        let twin = neighbors.first { $0.track.path == "popTwin" }?.distance ?? .infinity
        let intruder = neighbors.first { $0.track.path == "danceIntruder" }?.distance ?? .infinity
        XCTAssertLessThan(twin, intruder)
        XCTAssertEqual(intruder - twin, 2.0, accuracy: 1e-9)
    }

    func testNeighborsTreatUnknownGenreAsNeutral() {
        // Ehrlichkeitsgesetz: ein Kandidat ohne verwertbares Genre („Unknown") darf
        // keine Genre-Strafe bekommen — er zählt neutral wie ein Familien-Zwilling
        // und bleibt klar vor dem Fremdkörper anderer Familie.
        let anchor = makeFingerprint("anchor", year: 1993, duration: 240, mix: nil, genre: "Pop")
        let dataset = FingerprintDataset(tracks: [
            anchor,
            makeFingerprint("popTwin", year: 1993, duration: 240, mix: nil, genre: "Pop"),
            makeFingerprint("unknown", year: 1993, duration: 240, mix: nil, genre: "Unknown Genre"),
            makeFingerprint("danceIntruder", year: 1993, duration: 240, mix: nil, genre: "Dance")
        ])
        let neighbors = dataset.neighbors(of: anchor, limit: 10)
        func distance(_ path: String) -> Double {
            neighbors.first { $0.track.path == path }?.distance ?? .infinity
        }
        XCTAssertEqual(distance("unknown"), distance("popTwin"), accuracy: 1e-9)
        XCTAssertLessThan(distance("unknown"), distance("danceIntruder"))
    }
}
