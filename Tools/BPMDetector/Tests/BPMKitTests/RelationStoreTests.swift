//
// RelationStoreTests.swift
//
// Prüft die GRDB-Persistenz des Beziehungsgraphen: Roundtrip von Knoten und
// Kanten, die *lesbare* Speicherung der Entitätsart (String, nicht JSON), die
// Merge-Semantik (ein reicher Lookup ergänzt einen Stummel, ohne Fakten zu
// verlieren) und die Idempotenz der Kanten.
//

import XCTest
import GRDB
@testable import BPMKit

final class RelationStoreTests: XCTestCase {
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-test-\(UUID().uuidString).db").path
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    func testFragmentRoundTrip() throws {
        let store = try RelationStore(path: dbPath)
        let fragment = RelationGraphBuilder.Fragment(
            nodes: [
                GraphNode(mbid: "rec", kind: .recording, title: "Anker", artist: "Real McCoy", year: 1993),
                GraphNode(mbid: "rel", kind: .release, title: "Maxi", year: 1993),
            ],
            edges: [
                GraphEdge(sourceMBID: "rec", targetMBID: "rel", relation: "appears on", targetKind: .release),
            ]
        )
        try store.save(fragment)

        XCTAssertEqual(try store.entityCount(), 2)
        XCTAssertEqual(try store.edgeCount(), 1)

        let graph = try store.loadGraph()
        let anchor = try XCTUnwrap(graph.node("rec"))
        XCTAssertEqual(anchor.kind, .recording)
        XCTAssertEqual(anchor.artist, "Real McCoy")
        XCTAssertEqual(anchor.year, 1993)

        let neighbors = graph.neighbors(of: "rec")
        XCTAssertEqual(neighbors.count, 1)
        XCTAssertEqual(neighbors.first?.relation, "appears on")
        XCTAssertEqual(neighbors.first?.targetKind, .release)
    }

    /// Die Entitätsart muss als lesbarer String in der Spalte stehen (damit man
    /// die DB von Hand inspizieren und per SQL filtern kann) — nicht als
    /// JSON-Blob.
    func testKindIsStoredAsPlainString() throws {
        let store = try RelationStore(path: dbPath)
        try store.saveEntity(GraphNode(mbid: "rg", kind: .releaseGroup, title: "Album"))

        let raw = try DatabaseQueue(path: dbPath).read { db in
            try String.fetchOne(db, sql: "SELECT kind FROM mb_entities WHERE mbid = ?", arguments: ["rg"])
        }
        XCTAssertEqual(raw, "release-group")
    }

    func testMergeKeepsRicherFactsRegardlessOfOrder() throws {
        let store = try RelationStore(path: dbPath)
        // Zuerst der Stummel (aus einer Kante angelegt), dann der reiche Lookup.
        try store.saveEntity(GraphNode(mbid: "rel", kind: .release, title: "Maxi"))
        try store.saveEntity(GraphNode(mbid: "rel", kind: .release, title: "Maxi", year: 1993, label: "Logic Records", primaryType: "Single"))

        var node = try XCTUnwrap(try store.entity(mbid: "rel"))
        XCTAssertEqual(node.label, "Logic Records")
        XCTAssertEqual(node.year, 1993)

        // Umgekehrt: der reiche Knoten steht schon, ein späterer Stummel (nur
        // Titel, kein Label) darf das Label nicht wegwischen.
        try store.saveEntity(GraphNode(mbid: "rel", kind: .release, title: "Maxi (Reissue)"))
        node = try XCTUnwrap(try store.entity(mbid: "rel"))
        XCTAssertEqual(node.label, "Logic Records", "Ein späteres nil darf den Fakt nicht leeren")
        XCTAssertEqual(node.title, "Maxi (Reissue)", "Ein gesetzter neuer Wert gewinnt aber")
    }

    func testEdgeUpsertDoesNotDuplicate() throws {
        let store = try RelationStore(path: dbPath)
        let edge = GraphEdge(sourceMBID: "a", targetMBID: "b", relation: "remix of", targetKind: .recording)
        try store.saveEdge(edge)
        try store.saveEdge(edge)
        XCTAssertEqual(try store.edgeCount(), 1)

        // Andere Beziehung zwischen denselben Knoten ist eine eigene Kante.
        try store.saveEdge(GraphEdge(sourceMBID: "a", targetMBID: "b", relation: "appears on", targetKind: .release))
        XCTAssertEqual(try store.edgeCount(), 2)
    }

    func testEntitiesByTitleSubstring() throws {
        let store = try RelationStore(path: dbPath)
        try store.saveEntity(GraphNode(mbid: "1", kind: .recording, title: "Another Night", year: 1993))
        try store.saveEntity(GraphNode(mbid: "2", kind: .recording, title: "Another Day", year: 1994))
        try store.saveEntity(GraphNode(mbid: "3", kind: .recording, title: "Runaway", year: 1995))

        let hits = try store.entities(titleContains: "another")   // case-insensitiv
        XCTAssertEqual(hits.map(\.mbid), ["1", "2"])   // nach Jahr sortiert
    }
}
