//
// LibraryMBIDReaderTests.swift
//
// Prüft das Herausziehen der Recording-MBIDs aus einer Musicae-Bibliotheks-DB:
// das JSON-Feld `musicBrainzTrackId`, das Überspringen von Titeln ohne (oder mit
// unbrauchbarer) MBID und die Deduplizierung. Baut dafür eine synthetische
// `tracks`-Tabelle mit genau den gelesenen Spalten.
//

import XCTest
import GRDB
@testable import BPMKit

final class LibraryMBIDReaderTests: XCTestCase {
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-test-\(UUID().uuidString).db").path
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    /// Legt eine minimale `tracks`-Tabelle an und füllt sie mit den Zeilen.
    private func seedLibrary(_ rows: [(path: String, title: String?, artist: String?, extended: String?)]) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE tracks (
                    path TEXT NOT NULL,
                    title TEXT,
                    artist TEXT,
                    extended_metadata TEXT
                )
            """)
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO tracks (path, title, artist, extended_metadata) VALUES (?, ?, ?, ?)",
                    arguments: [row.path, row.title, row.artist, row.extended]
                )
            }
        }
    }

    func testExtractRecordingMBIDFromJSON() {
        let json = #"{"barcode":"123","musicBrainzTrackId":"11111111-1111-1111-1111-111111111111","key":"Am"}"#
        XCTAssertEqual(LibraryMBIDReader.recordingMBID(fromJSON: json), "11111111-1111-1111-1111-111111111111")

        // Kein MBID-Feld → nil.
        XCTAssertNil(LibraryMBIDReader.recordingMBID(fromJSON: #"{"barcode":"123"}"#))
        // Leer → nil.
        XCTAssertNil(LibraryMBIDReader.recordingMBID(fromJSON: #"{"musicBrainzTrackId":""}"#))
        // Keine gültige UUID → nil.
        XCTAssertNil(LibraryMBIDReader.recordingMBID(fromJSON: #"{"musicBrainzTrackId":"nope"}"#))
        // Kaputtes JSON → nil (kein Absturz).
        XCTAssertNil(LibraryMBIDReader.recordingMBID(fromJSON: "{not json"))
    }

    func testReadsOnlyTracksWithValidMBID() throws {
        try seedLibrary([
            (path: "/m/a.mp3", title: "Another Night", artist: "Real McCoy",
             extended: #"{"musicBrainzTrackId":"11111111-1111-1111-1111-111111111111"}"#),
            (path: "/m/b.mp3", title: "No MBID", artist: "X", extended: #"{"barcode":"42"}"#),
            (path: "/m/c.mp3", title: "Null Meta", artist: "Y", extended: nil),
            (path: "/m/d.m4a", title: "Runaway", artist: "Real McCoy",
             extended: #"{"musicBrainzTrackId":"22222222-2222-2222-2222-222222222222"}"#),
        ])

        let refs = try LibraryMBIDReader.recordingRefs(fromLibraryAt: dbPath)
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs.map(\.recordingMBID).sorted(), [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
        ])
        let first = try XCTUnwrap(refs.first { $0.path == "/m/a.mp3" })
        XCTAssertEqual(first.title, "Another Night")
        XCTAssertEqual(first.artist, "Real McCoy")
    }

    func testDeduplicatesRepeatedMBIDs() throws {
        // Zwei Dateien mit derselben Recording-MBID (z. B. Radio- und
        // Extended-Datei) → nur ein Anker im Graphen.
        let mbid = "33333333-3333-3333-3333-333333333333"
        try seedLibrary([
            (path: "/m/radio.mp3", title: "Song (Radio)", artist: "A", extended: #"{"musicBrainzTrackId":"\#(mbid)"}"#),
            (path: "/m/ext.mp3", title: "Song (Extended)", artist: "A", extended: #"{"musicBrainzTrackId":"\#(mbid)"}"#),
        ])
        let refs = try LibraryMBIDReader.recordingRefs(fromLibraryAt: dbPath)
        XCTAssertEqual(refs.count, 1)
    }
}
