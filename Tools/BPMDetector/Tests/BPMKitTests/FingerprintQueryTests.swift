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
        dynamic: Double = 6
    ) -> TrackFingerprint {
        TrackFingerprint(
            path: path,
            title: path,
            artist: "Künstler",
            album: "Album",
            year: year,
            durationSeconds: duration,
            bpm: bpm,
            bpmConfidence: bpm == nil ? nil : 0.8,
            axes: AudioAxes(rmsLoudnessDb: loudness, dynamicRangeDb: dynamic, spectralBrightnessHz: 1200, bassRatio: bass),
            mixVersion: mix,
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
}
