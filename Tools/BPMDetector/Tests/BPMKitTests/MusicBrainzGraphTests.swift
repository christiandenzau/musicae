//
// MusicBrainzGraphTests.swift
//
// Prüft das Herzstück von Phase 4 ohne Netz: das Mapping einer rohen
// MusicBrainz-Antwort auf Knoten und Kanten (`RelationGraphBuilder`), die
// lesbaren Beziehungslabels, das Jahr-Parsing und das Durchwandern des Graphen.
// Fixtures sind echte WS/2-JSON-Struktur, gekürzt auf die genutzten Felder.
//

import XCTest
@testable import BPMKit

final class MusicBrainzGraphTests: XCTestCase {

    // MARK: - Fixtures

    /// Ein Recording mit zwei Releases und je einer Remix- und Cover-Beziehung.
    private let recordingJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "title": "Another Night",
      "first-release-date": "1993",
      "artist-credit": [
        { "name": "Real McCoy", "joinphrase": "", "artist": { "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "name": "Real McCoy" } }
      ],
      "releases": [
        { "id": "22222222-2222-2222-2222-222222222222", "title": "Another Night", "date": "1993-09-06", "status": "Official" },
        { "id": "33333333-3333-3333-3333-333333333333", "title": "Space Invaders", "date": "1994", "status": "Official" }
      ],
      "relations": [
        { "type": "remix", "direction": "backward", "target-type": "recording",
          "recording": { "id": "44444444-4444-4444-4444-444444444444", "title": "Another Night (Original Mix)", "first-release-date": "1992" } },
        { "type": "cover", "direction": "backward", "target-type": "work",
          "work": { "id": "55555555-5555-5555-5555-555555555555", "title": "Another Night" } }
      ]
    }
    """

    /// Ein Release mit Label und Release-Gruppe (für die Anreicherung).
    private let releaseJSON = """
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "title": "Another Night",
      "date": "1993-09-06",
      "label-info": [
        { "catalog-number": "74321 16797 2", "label": { "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "name": "Logic Records" } }
      ],
      "release-group": { "id": "66666666-6666-6666-6666-666666666666", "title": "Another Night", "primary-type": "Single", "first-release-date": "1993" }
    }
    """

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Builder: Recording

    func testRecordingFragmentNodesAndEdges() throws {
        let recording = try decode(recordingJSON, as: MBRecording.self)
        let fragment = RelationGraphBuilder.fragment(from: recording)

        // Der Aufnahme-Knoten selbst.
        let anchor = try XCTUnwrap(fragment.nodes.first { $0.mbid == "11111111-1111-1111-1111-111111111111" })
        XCTAssertEqual(anchor.kind, .recording)
        XCTAssertEqual(anchor.title, "Another Night")
        XCTAssertEqual(anchor.artist, "Real McCoy")
        XCTAssertEqual(anchor.year, 1993)

        // Zwei Releases, jeweils per „appears on"-Kante.
        let appearsOn = fragment.edges.filter { $0.relation == "appears on" }
        XCTAssertEqual(Set(appearsOn.map(\.targetMBID)), [
            "22222222-2222-2222-2222-222222222222",
            "33333333-3333-3333-3333-333333333333",
        ])
        XCTAssertTrue(appearsOn.allSatisfy { $0.targetKind == .release })

        // Das zweite Release trägt sein Jahr aus dem Datum.
        let secondRelease = try XCTUnwrap(fragment.nodes.first { $0.mbid == "33333333-3333-3333-3333-333333333333" })
        XCTAssertEqual(secondRelease.year, 1994)
    }

    func testRecordingFragmentRelationDirections() throws {
        let recording = try decode(recordingJSON, as: MBRecording.self)
        let fragment = RelationGraphBuilder.fragment(from: recording)

        // Remix rückwärts → „remix of", Ziel ist ein Recording (mit eigenem Jahr).
        let remix = try XCTUnwrap(fragment.edges.first { $0.relation == "remix of" })
        XCTAssertEqual(remix.targetMBID, "44444444-4444-4444-4444-444444444444")
        XCTAssertEqual(remix.targetKind, .recording)
        let remixTarget = try XCTUnwrap(fragment.nodes.first { $0.mbid == remix.targetMBID })
        XCTAssertEqual(remixTarget.year, 1992)

        // Cover rückwärts → „cover of", Ziel ist ein Werk.
        let cover = try XCTUnwrap(fragment.edges.first { $0.relation == "cover of" })
        XCTAssertEqual(cover.targetMBID, "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(cover.targetKind, .work)
    }

    // MARK: - Builder: Release-Anreicherung

    func testReleaseFragmentCarriesLabelAndGroup() throws {
        let release = try decode(releaseJSON, as: MBRelease.self)
        let fragment = RelationGraphBuilder.fragment(fromRelease: release)

        let releaseNode = try XCTUnwrap(fragment.nodes.first { $0.mbid == "22222222-2222-2222-2222-222222222222" })
        XCTAssertEqual(releaseNode.kind, .release)
        XCTAssertEqual(releaseNode.label, "Logic Records")
        XCTAssertEqual(releaseNode.primaryType, "Single")
        XCTAssertEqual(releaseNode.year, 1993)

        // Kante Release → Release-Gruppe.
        let groupEdge = try XCTUnwrap(fragment.edges.first { $0.relation == "release of" })
        XCTAssertEqual(groupEdge.targetMBID, "66666666-6666-6666-6666-666666666666")
        XCTAssertEqual(groupEdge.targetKind, .releaseGroup)
        let group = try XCTUnwrap(fragment.nodes.first { $0.mbid == groupEdge.targetMBID })
        XCTAssertEqual(group.primaryType, "Single")
    }

    // MARK: - Reine Helfer

    func testRelationLabelDirections() {
        XCTAssertEqual(relationLabel(type: "remix", direction: "backward"), "remix of")
        XCTAssertEqual(relationLabel(type: "remix", direction: "forward"), "has remix")
        XCTAssertEqual(relationLabel(type: "cover", direction: "backward"), "cover of")
        XCTAssertEqual(relationLabel(type: "samples material", direction: "backward"), "samples")
        // Unbekannter Typ behält seinen Namen, rückwärts mit Pfeil markiert.
        XCTAssertEqual(relationLabel(type: "DJ-mix", direction: "backward"), "dj-mix (←)")
        XCTAssertEqual(relationLabel(type: nil, direction: nil), "related")
    }

    func testYearFromDate() {
        XCTAssertEqual(year(fromDate: "1993"), 1993)
        XCTAssertEqual(year(fromDate: "1993-09-06"), 1993)
        XCTAssertEqual(year(fromDate: "2001-1-1"), 2001)
        XCTAssertNil(year(fromDate: ""))
        XCTAssertNil(year(fromDate: nil))
        XCTAssertNil(year(fromDate: "not-a-date"))
        XCTAssertNil(year(fromDate: "1899"))   // vor dem plausiblen Fenster
    }

    func testEntityKindFromTargetType() {
        XCTAssertEqual(MBEntityKind.from(targetType: "recording"), .recording)
        XCTAssertEqual(MBEntityKind.from(targetType: "release-group"), .releaseGroup)
        XCTAssertEqual(MBEntityKind.from(targetType: "Artist"), .artist)   // tolerant
        XCTAssertEqual(MBEntityKind.from(targetType: "series"), .unknown)
        XCTAssertEqual(MBEntityKind.from(targetType: nil), .unknown)
    }

    func testArtistCreditDisplayNameJoinsParts() throws {
        let json = """
        [
          { "name": "2 Unlimited", "joinphrase": " feat. ", "artist": { "name": "2 Unlimited" } },
          { "name": "Ray", "joinphrase": " & ", "artist": { "name": "Ray" } },
          { "name": "Anita", "joinphrase": "", "artist": { "name": "Anita" } }
        ]
        """
        let credits = try decode(json, as: [MBArtistCredit].self)
        XCTAssertEqual(credits.displayName, "2 Unlimited feat. Ray & Anita")
    }

    // MARK: - Traversierung

    func testWalkFollowsThreadInBreadth() throws {
        // recording → release → release-group; recording → remix (recording)
        let nodes = [
            GraphNode(mbid: "rec", kind: .recording, title: "Anker"),
            GraphNode(mbid: "rel", kind: .release, title: "Maxi", year: 1995),
            GraphNode(mbid: "grp", kind: .releaseGroup, title: "Album", primaryType: "Album"),
            GraphNode(mbid: "remix", kind: .recording, title: "Original"),
        ]
        let edges = [
            GraphEdge(sourceMBID: "rec", targetMBID: "rel", relation: "appears on", targetKind: .release),
            GraphEdge(sourceMBID: "rec", targetMBID: "remix", relation: "remix of", targetKind: .recording),
            GraphEdge(sourceMBID: "rel", targetMBID: "grp", relation: "release of", targetKind: .releaseGroup),
        ]
        let graph = RelationGraph(nodes: nodes, edges: edges)

        // Tiefe 1: nur die direkten Nachbarn des Ankers.
        let shallow = graph.walk(from: "rec", maxDepth: 1)
        XCTAssertEqual(shallow.count, 2)
        XCTAssertTrue(shallow.allSatisfy { $0.depth == 1 })

        // Tiefe 2: erreicht die Release-Gruppe über das Release.
        let deep = graph.walk(from: "rec", maxDepth: 2)
        let groupStep = try XCTUnwrap(deep.first { $0.edge.targetMBID == "grp" })
        XCTAssertEqual(groupStep.depth, 2)
        XCTAssertEqual(groupStep.target?.primaryType, "Album")
    }

    func testWalkTerminatesOnCycle() {
        // a ↔ b: gegenseitige Kanten dürfen nicht endlos wandern.
        let nodes = [GraphNode(mbid: "a", kind: .recording), GraphNode(mbid: "b", kind: .recording)]
        let edges = [
            GraphEdge(sourceMBID: "a", targetMBID: "b", relation: "remix of", targetKind: .recording),
            GraphEdge(sourceMBID: "b", targetMBID: "a", relation: "has remix", targetKind: .recording),
        ]
        let graph = RelationGraph(nodes: nodes, edges: edges)
        let steps = graph.walk(from: "a", maxDepth: 10)
        // Genau zwei Kanten, jede einmal — kein Endlospfad.
        XCTAssertEqual(steps.count, 2)
    }

    func testNeighborsAreSortedDeterministically() {
        let nodes = [GraphNode(mbid: "x", kind: .recording)]
        let edges = [
            GraphEdge(sourceMBID: "x", targetMBID: "z2", relation: "appears on", targetKind: .release),
            GraphEdge(sourceMBID: "x", targetMBID: "z1", relation: "appears on", targetKind: .release),
            GraphEdge(sourceMBID: "x", targetMBID: "y", relation: "remix of", targetKind: .recording),
        ]
        let graph = RelationGraph(nodes: nodes, edges: edges)
        let neighbors = graph.neighbors(of: "x")
        XCTAssertEqual(neighbors.map { "\($0.relation)→\($0.targetMBID)" },
                       ["appears on→z1", "appears on→z2", "remix of→y"])
    }
}
