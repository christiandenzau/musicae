//
// MusicBrainzClient.swift
//
// Der kleine, ratenbegrenzte Client für die MusicBrainz-Web-API (Phase 4, #7).
// Bewusst schmal: er holt genau die zwei Entitäten, die der Faden der
// Testscheibe braucht (Recording, Release), beachtet die Ratenbegrenzung von
// ~1 Anfrage/Sekunde und setzt den von MusicBrainz *verpflichtend* verlangten,
// aussagekräftigen User-Agent.
//
// Der Netz-Zugriff steckt hinter `HTTPFetching`: im Betrieb `URLSession`, im
// Test ein fester Fake ohne Netz. So sind Rate-Limiter, URL-Bau, Statusprüfung
// und JSON-Dekodierung ohne echte Anfragen prüfbar.
//
// Referenz: https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting
//

import Foundation

// MARK: - Transport

/// Die minimale HTTP-Fähigkeit, die der Client braucht — eine Anfrage rein,
/// Daten + Antwort raus. `URLSession` erfüllt sie im Betrieb; Tests reichen
/// einen Fake.
public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPFetching {
    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MusicBrainzError.invalidResponse
        }
        return (data, http)
    }
}

// MARK: - Ratenbegrenzung

/// Erzwingt einen Mindestabstand zwischen Anfragestarts. Als `actor`
/// serialisiert er nebenläufige Aufrufe von selbst: jeder `waitForTurn()` kehrt
/// frühestens ein Intervall nach dem vorigen zurück. MusicBrainz duldet im
/// Schnitt ~1 Anfrage/Sekunde je Client — mehr riskiert 503-Sperren.
public actor RateLimiter {
    private let interval: Duration
    private let clock = ContinuousClock()
    private var lastTurn: ContinuousClock.Instant?

    public init(minimumInterval: Duration = .seconds(1)) {
        self.interval = minimumInterval
    }

    /// Wartet, bis seit dem letzten Turn mindestens ein Intervall vergangen ist,
    /// und markiert den neuen Turn.
    public func waitForTurn() async {
        if let last = lastTurn {
            let elapsed = clock.now - last
            if elapsed < interval {
                try? await clock.sleep(for: interval - elapsed)
            }
        }
        lastTurn = clock.now
    }
}

// MARK: - Fehler

public enum MusicBrainzError: Error, Sendable, Equatable {
    case invalidMBID(String)
    case invalidResponse
    case httpStatus(Int)
    case rateLimited
    case decoding(String)
}

// MARK: - Client

public struct MusicBrainzClient: Sendable {
    private let http: any HTTPFetching
    private let limiter: RateLimiter
    private let baseURL: URL
    private let userAgent: String

    /// Die `inc`-Parameter, die aus einem Recording-Lookup den Faden holen:
    /// Künstler (für die Anzeige), Releases (die Maxi/das Album) und die
    /// Beziehungen auf Aufnahme- und Werk-Ebene (Remix-von, Cover-von).
    public static let recordingIncludes = "artist-credits+releases+recording-rels+work-rels"
    /// Für den Release-Lookup: Label und Release-Gruppe (das „Album").
    public static let releaseIncludes = "labels+release-groups"

    /// - Parameters:
    ///   - contact: Kontakt (URL oder E-Mail) für den User-Agent — von
    ///     MusicBrainz verlangt, damit ein Client identifizierbar bleibt.
    ///   - http: Transport (Default `URLSession.shared`).
    ///   - limiter: Ratenbegrenzer (Default 1 Anfrage/Sekunde).
    ///   - baseURL: API-Wurzel (Default die offizielle; überschreibbar für Tests/Mirror).
    public init(
        contact: String = "https://github.com/christiandenzau/musicae",
        http: any HTTPFetching = URLSession.shared,
        limiter: RateLimiter = RateLimiter(),
        baseURL: URL = URL(string: "https://musicbrainz.org/ws/2/")!
    ) {
        self.http = http
        self.limiter = limiter
        self.baseURL = baseURL
        self.userAgent = "Musicae/0.1 ( \(contact) )"
    }

    // MARK: Öffentliche Lookups

    /// Holt eine Aufnahme samt Releases und Beziehungen.
    public func lookupRecording(mbid: String) async throws -> MBRecording {
        try await lookup(entity: "recording", mbid: mbid, includes: Self.recordingIncludes)
    }

    /// Holt einen Tonträger samt Label und Release-Gruppe.
    public func lookupRelease(mbid: String) async throws -> MBRelease {
        try await lookup(entity: "release", mbid: mbid, includes: Self.releaseIncludes)
    }

    // MARK: Intern

    private func lookup<T: Decodable>(entity: String, mbid: String, includes: String) async throws -> T {
        guard UUID(uuidString: mbid) != nil else { throw MusicBrainzError.invalidMBID(mbid) }
        let request = makeRequest(url: try lookupURL(entity: entity, mbid: mbid, includes: includes))

        await limiter.waitForTurn()
        let (data, response) = try await http.fetch(request)

        switch response.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw MusicBrainzError.decoding(String(describing: error))
            }
        case 503:
            throw MusicBrainzError.rateLimited
        default:
            throw MusicBrainzError.httpStatus(response.statusCode)
        }
    }

    /// Baut `<base>/<entity>/<mbid>?fmt=json&inc=<includes>`. `inc` nutzt „+" als
    /// Trenner (MusicBrainz-Konvention) — bewusst nicht prozentkodiert.
    func lookupURL(entity: String, mbid: String, includes: String) throws -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(entity).appendingPathComponent(mbid),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: includes),
        ]
        guard let url = components?.url else { throw MusicBrainzError.invalidMBID(mbid) }
        return url
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }
}
