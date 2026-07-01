//
// RelationIngestor.swift
//
// Die Orchestrierung von Phase 4 (#7): für eine Liste von Recording-MBIDs die
// Fakten und Beziehungen über den ratenbegrenzten `MusicBrainzClient` holen, zu
// Knoten und Kanten falten (`RelationGraphBuilder`) und in den `RelationStore`
// schreiben. Optional werden die dabei entdeckten Releases in einem zweiten
// Schritt angereichert (Label, Release-Gruppe) — der Faden „Maxi → Album des
// Jahres, mit Label".
//
// Seriell: die Ratenbegrenzung serialisiert die Anfragen ohnehin, und seriell
// bleibt der Fortschritt ehrlich zählbar. Ein einzelner Fehlschlag (fehlende
// MBID, 404) stoppt den Lauf nicht — er landet im Report.
//

import Foundation

/// Was ein Ingest-Lauf bewirkt hat.
public struct IngestReport: Sendable, Equatable {
    public var recordingsFetched = 0
    public var recordingsFailed = 0
    public var releasesEnriched = 0
    public var releasesFailed = 0
    public var failures: [IngestFailure] = []
}

/// Ein einzelner Fehlschlag, für den Report.
public struct IngestFailure: Sendable, Equatable {
    public var mbid: String
    public var kind: String   // „recording" | „release"
    public var message: String
}

public struct RelationIngestor {
    private let client: MusicBrainzClient
    private let store: RelationStore

    public init(client: MusicBrainzClient, store: RelationStore) {
        self.client = client
        self.store = store
    }

    /// Fortschritts-Nachricht während des Laufs.
    public struct Progress: Sendable {
        public let done: Int
        public let total: Int
        public let phase: String   // „recording" | „release"
        public let mbid: String
    }

    /// Holt und speichert den Graphen für die gegebenen Recording-MBIDs.
    ///
    /// - Parameters:
    ///   - recordingMBIDs: die MBIDs der Scheibe (Duplikate werden zusammengefasst).
    ///   - enrichReleases: die entdeckten Releases zusätzlich mit Label und
    ///     Release-Gruppe anreichern (ein Lookup je eindeutigem Release).
    ///   - onProgress: optionaler Fortschritts-Rückruf (je Anfrage einmal).
    public func ingest(
        recordingMBIDs: [String],
        enrichReleases: Bool = true,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> IngestReport {
        var report = IngestReport()
        let recordings = orderedUnique(recordingMBIDs)
        var releaseIDs: [String] = []
        var seenReleases = Set<String>()

        // Schritt 1: Aufnahmen holen, Kanten schreiben, Releases einsammeln.
        for (index, mbid) in recordings.enumerated() {
            onProgress?(Progress(done: index + 1, total: recordings.count, phase: "recording", mbid: mbid))
            do {
                let recording = try await client.lookupRecording(mbid: mbid)
                let fragment = RelationGraphBuilder.fragment(from: recording)
                try store.save(fragment)
                report.recordingsFetched += 1
                for edge in fragment.edges where edge.targetKind == .release {
                    if seenReleases.insert(edge.targetMBID).inserted {
                        releaseIDs.append(edge.targetMBID)
                    }
                }
            } catch {
                report.recordingsFailed += 1
                report.failures.append(IngestFailure(mbid: mbid, kind: "recording", message: describe(error)))
            }
        }

        guard enrichReleases else { return report }

        // Schritt 2: die entdeckten Releases anreichern (Label, Release-Gruppe).
        for (index, mbid) in releaseIDs.enumerated() {
            onProgress?(Progress(done: index + 1, total: releaseIDs.count, phase: "release", mbid: mbid))
            do {
                let release = try await client.lookupRelease(mbid: mbid)
                try store.save(RelationGraphBuilder.fragment(fromRelease: release))
                report.releasesEnriched += 1
            } catch {
                report.releasesFailed += 1
                report.failures.append(IngestFailure(mbid: mbid, kind: "release", message: describe(error)))
            }
        }

        return report
    }

    // MARK: - Intern

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func describe(_ error: Error) -> String {
        if let mbError = error as? MusicBrainzError {
            switch mbError {
            case .invalidMBID(let id): return "ungültige MBID: \(id)"
            case .invalidResponse: return "keine HTTP-Antwort"
            case .httpStatus(let code): return "HTTP \(code)"
            case .rateLimited: return "ratenbegrenzt (503)"
            case .decoding(let detail): return "JSON-Fehler: \(detail)"
            }
        }
        return String(describing: error)
    }
}
