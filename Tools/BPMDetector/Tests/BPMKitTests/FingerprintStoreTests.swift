//
// FingerprintStoreTests.swift
//
// Prüft die GRDB-Persistenz: Tabelle wird angelegt, Roundtrip stimmt, und ein
// erneuter Schreibvorgang gleichen Pfads ersetzt statt zu duplizieren (eine
// Zeile pro Track).
//

import XCTest
@testable import BPMKit

final class FingerprintStoreTests: XCTestCase {
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-test-\(UUID().uuidString).db")
            .path
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    private func makeFingerprint(path: String, bpm: Double?, mix: String?) -> TrackFingerprint {
        TrackFingerprint(
            path: path,
            title: "Beispieltitel",
            artist: "Beispielkünstler",
            album: "Beispielalbum",
            year: 1995,
            durationSeconds: 212.5,
            bpm: bpm,
            bpmConfidence: bpm == nil ? nil : 0.62,
            axes: AudioAxes(rmsLoudnessDb: -7.2, dynamicRangeDb: 9.4, spectralBrightnessHz: 1850, bassRatio: 0.38),
            mixVersion: mix,
            analyzedAt: Date()
        )
    }

    func testRoundTrip() throws {
        let store = try FingerprintStore(path: dbPath)
        let written = makeFingerprint(path: "/music/track.m4a", bpm: 140.3, mix: "Extended Mix")
        try store.save(written)

        let read = try XCTUnwrap(store.fingerprint(forPath: "/music/track.m4a"))
        XCTAssertEqual(read.path, written.path)
        XCTAssertEqual(read.title, "Beispieltitel")
        XCTAssertEqual(read.artist, "Beispielkünstler")
        XCTAssertEqual(read.album, "Beispielalbum")
        XCTAssertEqual(read.year, 1995)
        XCTAssertEqual(read.durationSeconds, 212.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(read.bpm), 140.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(read.bpmConfidence), 0.62, accuracy: 0.001)
        XCTAssertEqual(read.rmsLoudnessDb, -7.2, accuracy: 0.001)
        XCTAssertEqual(read.dynamicRangeDb, 9.4, accuracy: 0.001)
        XCTAssertEqual(read.spectralBrightnessHz, 1850, accuracy: 0.001)
        XCTAssertEqual(read.bassRatio, 0.38, accuracy: 0.001)
        XCTAssertEqual(read.mixVersion, "Extended Mix")
    }

    func testUpsertReplacesSamePath() throws {
        let store = try FingerprintStore(path: dbPath)
        try store.save(makeFingerprint(path: "/music/track.m4a", bpm: 128, mix: "Radio Edit"))
        try store.save(makeFingerprint(path: "/music/track.m4a", bpm: 145, mix: "Club Mix"))

        XCTAssertEqual(try store.count(), 1, "Gleicher Pfad darf nicht duplizieren")
        let read = try XCTUnwrap(store.fingerprint(forPath: "/music/track.m4a"))
        XCTAssertEqual(try XCTUnwrap(read.bpm), 145, accuracy: 0.001)
        XCTAssertEqual(read.mixVersion, "Club Mix")
    }

    func testNilFieldsPersist() throws {
        let store = try FingerprintStore(path: dbPath)
        try store.save(makeFingerprint(path: "/music/no-bpm.m4a", bpm: nil, mix: nil))

        let read = try XCTUnwrap(store.fingerprint(forPath: "/music/no-bpm.m4a"))
        XCTAssertNil(read.bpm)
        XCTAssertNil(read.bpmConfidence)
        XCTAssertNil(read.mixVersion)
    }

    func testCountAcrossDistinctTracks() throws {
        let store = try FingerprintStore(path: dbPath)
        for index in 0..<5 {
            try store.save(makeFingerprint(path: "/music/track-\(index).m4a", bpm: 130 + Double(index), mix: nil))
        }
        XCTAssertEqual(try store.count(), 5)
    }
}
