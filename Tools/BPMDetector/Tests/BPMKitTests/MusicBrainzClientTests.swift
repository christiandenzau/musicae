//
// MusicBrainzClientTests.swift
//
// Prüft den Netz-Client ohne Netz: URL-Bau, den verpflichtenden User-Agent, die
// Statusabbildung, die MBID-Validierung, den Ratenabstand und den kompletten
// Ingest-Weg (Fake-HTTP → Builder → Store → Report). Der Transport ist ein
// fester Stub, der Anfragen aufzeichnet und je nach Pfad antwortet.
//

import XCTest
@testable import BPMKit

// MARK: - Fake-Transport

/// Ein HTTP-Stub: routet je Anfrage zu einer festen Antwort und zeichnet alle
/// gestellten Anfragen auf (für Zusicherungen über URL und Header).
final class StubHTTP: HTTPFetching, @unchecked Sendable {
    struct Reply { let status: Int; let body: Data }
    private let route: @Sendable (URLRequest) -> Reply
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { _requests } }

    init(route: @escaping @Sendable (URLRequest) -> Reply) { self.route = route }

    /// Bequemer Konstruktor: fester Statuscode und JSON-Text für alle Anfragen.
    convenience init(status: Int = 200, json: String) {
        self.init { _ in Reply(status: status, body: Data(json.utf8)) }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let reply = route(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (reply.body, response)
    }
}

final class MusicBrainzClientTests: XCTestCase {
    private let validMBID = "11111111-1111-1111-1111-111111111111"

    // MARK: - URL & Header

    func testLookupBuildsCorrectURLAndUserAgent() async throws {
        let stub = StubHTTP(json: #"{ "id": "11111111-1111-1111-1111-111111111111" }"#)
        let client = MusicBrainzClient(contact: "test@example.com", http: stub)

        _ = try await client.lookupRecording(mbid: validMBID)

        let request = try XCTUnwrap(stub.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "musicbrainz.org")
        XCTAssertTrue(url.path.hasSuffix("/ws/2/recording/\(validMBID)"), "Pfad war \(url.path)")

        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "fmt", value: "json")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "inc", value: MusicBrainzClient.recordingIncludes)))

        // Der User-Agent ist Pflicht bei MusicBrainz und muss den Kontakt tragen.
        let userAgent = try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(userAgent.contains("Musicae/"))
        XCTAssertTrue(userAgent.contains("test@example.com"))
    }

    func testReleaseLookupUsesReleaseIncludes() async throws {
        let stub = StubHTTP(json: #"{ "id": "11111111-1111-1111-1111-111111111111" }"#)
        let client = MusicBrainzClient(contact: "c", http: stub)
        _ = try await client.lookupRelease(mbid: validMBID)

        let url = try XCTUnwrap(stub.requests.first?.url)
        XCTAssertTrue(url.path.hasSuffix("/release/\(validMBID)"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "inc", value: MusicBrainzClient.releaseIncludes)))
    }

    // MARK: - Fehlerfälle

    func testInvalidMBIDIsRejectedBeforeAnyRequest() async {
        let stub = StubHTTP(json: "{}")
        let client = MusicBrainzClient(contact: "c", http: stub)
        do {
            _ = try await client.lookupRecording(mbid: "nicht-uuid")
            XCTFail("Sollte werfen")
        } catch {
            XCTAssertEqual(error as? MusicBrainzError, .invalidMBID("nicht-uuid"))
        }
        XCTAssertTrue(stub.requests.isEmpty, "Bei ungültiger MBID darf keine Anfrage rausgehen")
    }

    func testHTTPStatusMapping() async {
        func client(status: Int) -> MusicBrainzClient {
            MusicBrainzClient(contact: "c", http: StubHTTP(status: status, json: "{}"))
        }
        // 503 → rate limited
        do { _ = try await client(status: 503).lookupRecording(mbid: validMBID); XCTFail() }
        catch { XCTAssertEqual(error as? MusicBrainzError, .rateLimited) }
        // 404 → httpStatus
        do { _ = try await client(status: 404).lookupRecording(mbid: validMBID); XCTFail() }
        catch { XCTAssertEqual(error as? MusicBrainzError, .httpStatus(404)) }
    }

    func testMalformedJSONThrowsDecodingError() async {
        let client = MusicBrainzClient(contact: "c", http: StubHTTP(json: "{ this is not json"))
        do {
            _ = try await client.lookupRecording(mbid: validMBID)
            XCTFail("Sollte werfen")
        } catch {
            guard case .decoding = (error as? MusicBrainzError) else {
                return XCTFail("Erwartet .decoding, war \(error)")
            }
        }
    }

    // MARK: - Ratenbegrenzung

    func testRateLimiterEnforcesSpacing() async {
        let limiter = RateLimiter(minimumInterval: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<3 { await limiter.waitForTurn() }
        let elapsed = clock.now - start
        // Erster Turn sofort, dann 2× ~100 ms Abstand → ≥ ~200 ms. Konservativ ≥ 150.
        XCTAssertGreaterThan(elapsed, .milliseconds(150), "Ratenabstand wurde nicht eingehalten")
        XCTAssertLessThan(elapsed, .seconds(2), "Unerwartet langsam")
    }

    func testRateLimiterFirstCallIsImmediate() async {
        let limiter = RateLimiter(minimumInterval: .seconds(5))
        let clock = ContinuousClock()
        let start = clock.now
        await limiter.waitForTurn()   // darf nicht auf das Intervall warten
        XCTAssertLessThan(clock.now - start, .seconds(1))
    }

    // MARK: - Ingest (End-to-End, ohne Netz)

    func testIngestFetchesRecordingsAndEnrichesReleases() async throws {
        let recordingJSON = """
        {
          "id": "\(validMBID)",
          "title": "Another Night",
          "first-release-date": "1993",
          "artist-credit": [ { "name": "Real McCoy", "artist": { "name": "Real McCoy" } } ],
          "releases": [
            { "id": "22222222-2222-2222-2222-222222222222", "title": "Another Night", "date": "1993-09-06" }
          ],
          "relations": [
            { "type": "remix", "direction": "backward", "target-type": "recording",
              "recording": { "id": "44444444-4444-4444-4444-444444444444", "title": "Original Mix" } }
          ]
        }
        """
        let releaseJSON = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "title": "Another Night",
          "date": "1993-09-06",
          "label-info": [ { "label": { "name": "Logic Records" } } ],
          "release-group": { "id": "66666666-6666-6666-6666-666666666666", "title": "Another Night", "primary-type": "Single" }
        }
        """
        // Router: Recording-Pfad → recordingJSON, Release-Pfad → releaseJSON.
        let stub = StubHTTP { request in
            let path = request.url?.path ?? ""
            if path.contains("/recording/") { return .init(status: 200, body: Data(recordingJSON.utf8)) }
            if path.contains("/release/") { return .init(status: 200, body: Data(releaseJSON.utf8)) }
            return .init(status: 404, body: Data("{}".utf8))
        }

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-ingest-\(UUID().uuidString).db").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) } }

        let store = try RelationStore(path: dbPath)
        // Schneller Limiter, damit der Test nicht real 1 s/Anfrage wartet.
        let client = MusicBrainzClient(contact: "c", http: stub, limiter: RateLimiter(minimumInterval: .milliseconds(1)))
        let ingestor = RelationIngestor(client: client, store: store)

        let report = await ingestor.ingest(recordingMBIDs: [validMBID, validMBID])   // Duplikat → 1×

        XCTAssertEqual(report.recordingsFetched, 1, "Duplikate werden zusammengefasst")
        XCTAssertEqual(report.releasesEnriched, 1)
        XCTAssertTrue(report.failures.isEmpty, "Fehler: \(report.failures)")

        // Der Graph steht: Anker → Release → Release-Gruppe, plus Remix-Kante.
        let graph = try store.loadGraph()
        let anchorNeighbors = graph.neighbors(of: validMBID)
        XCTAssertEqual(Set(anchorNeighbors.map(\.relation)), ["appears on", "remix of"])

        // Das Release wurde angereichert (Label kam erst aus dem Release-Lookup).
        let release = try XCTUnwrap(graph.node("22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(release.label, "Logic Records")

        // Der begehbare Faden erreicht die Release-Gruppe (das „Album").
        let walk = graph.walk(from: validMBID, maxDepth: 2)
        XCTAssertTrue(walk.contains { $0.edge.targetMBID == "66666666-6666-6666-6666-666666666666" })
    }

    func testIngestRecordsFailuresWithoutStopping() async throws {
        // Erste MBID 404, zweite ok — der Lauf darf nicht abbrechen.
        let okID = "77777777-7777-7777-7777-777777777777"
        let failID = validMBID   // lokal kopieren: die @Sendable-Closure darf kein `self` fangen
        let okBody = Data(#"{ "id": "\#(okID)", "title": "OK" }"#.utf8)
        let stub = StubHTTP { request in
            let path = request.url?.path ?? ""
            if path.contains(failID) { return .init(status: 404, body: Data("{}".utf8)) }
            return .init(status: 200, body: okBody)
        }
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-fail-\(UUID().uuidString).db").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) } }

        let store = try RelationStore(path: dbPath)
        let client = MusicBrainzClient(contact: "c", http: stub, limiter: RateLimiter(minimumInterval: .milliseconds(1)))
        let report = await RelationIngestor(client: client, store: store)
            .ingest(recordingMBIDs: [validMBID, okID], enrichReleases: false)

        XCTAssertEqual(report.recordingsFetched, 1)
        XCTAssertEqual(report.recordingsFailed, 1)
        XCTAssertEqual(report.failures.first?.mbid, validMBID)
        XCTAssertEqual(report.failures.first?.message, "HTTP 404")
    }
}
