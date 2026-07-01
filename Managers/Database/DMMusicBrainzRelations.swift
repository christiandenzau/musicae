//
// DatabaseManager class extension
//
// MusicBrainz relations graph (#18, "the walkable thread" from Phase 4): brings the graph
// built by BPMKit's `RelationStore`/`RelationIngestor` into the app. Two jobs:
//
//   • Reading — walk the stored graph outward from a track's recording MBID so the UI can
//     show its relations (appears-on → release → release-group, remix-of, …), at least one
//     level deep. The recording MBID comes from `extended_metadata.musicBrainzTrackId` in
//     `musicae.db`; the graph lives in its own `relations.db` (see `relationsDBPath`).
//   • Ingesting — a rate-limited (1 req/s) online run over the library's recording MBIDs,
//     the same online enrichment the app already does for artist bios. Idempotent (the
//     store merges), resumable, progress shown through the NotificationManager.
//
// The graph store is a separate SQLite file; `RelationStore` is created and used inside a
// detached task each time (never handed across an actor boundary), keeping this simple and
// race-free. Honesty law: no MBID, no graph, or no data for this track each get their own
// truthful state — never a guessed or misleading list.
//

import BPMKit
import Foundation
import GRDB

extension DatabaseManager {
    /// Outcome of walking the relations graph for a track, so the UI can tell the honest
    /// cases apart instead of showing one ambiguous empty view.
    enum RelationsResult: Sendable {
        /// The track carries no recording MBID — nothing to look up.
        case noMBID
        /// The relations graph is still empty (the load in Settings hasn't run yet).
        case noGraph
        /// The graph exists but doesn't contain this recording (its lookup failed or the
        /// library-wide run hasn't reached it) — no data for this track, honestly.
        case anchorMissing
        /// The walkable thread from the anchor: the anchor node plus its outgoing steps
        /// (may be empty if the recording has no stored relations).
        case thread(anchor: GraphNode, steps: [RelationGraph.Step])
    }

    /// Node/edge counts of the stored graph, for the Settings status line. `nil` when the
    /// graph is still empty.
    struct RelationsGraphStats: Sendable {
        let entities: Int
        let edges: Int
    }

    /// Guards against a second ingest starting while one is already running (two writers on
    /// the same `relations.db` would fight). MainActor-isolated so the check-and-set can't race.
    @MainActor private static var relationsIngestRunning = false

    // MARK: - Reading (walk the thread)

    /// Walks the relations graph outward from `trackId`'s recording MBID, `maxDepth` levels
    /// deep. Resolves the MBID from `musicae.db`, then reads the separate `relations.db`.
    func relationshipThread(forTrackId trackId: Int64, maxDepth: Int = 2) async -> RelationsResult {
        guard let mbid = await resolveRecordingMBID(trackId: trackId), !mbid.isEmpty else {
            return .noMBID
        }
        let path = relationsDBPath
        return await Task.detached(priority: .userInitiated) {
            guard let store = try? RelationStore(path: path),
                  let graph = try? store.loadGraph(), !graph.nodesByID.isEmpty else {
                return RelationsResult.noGraph
            }
            guard let anchor = graph.node(mbid) else {
                return .anchorMissing
            }
            return .thread(anchor: anchor, steps: graph.walk(from: mbid, maxDepth: maxDepth))
        }.value
    }

    /// Reads the recording MBID a track's tags already resolved into
    /// `extended_metadata.musicBrainzTrackId` (Schema-Karte §6). `nil` if absent.
    private func resolveRecordingMBID(trackId: Int64) async -> String? {
        do {
            return try await dbQueue.read { db -> String? in
                guard let row = try Row.fetchOne(
                        db,
                        sql: "SELECT extended_metadata FROM tracks WHERE id = ?",
                        arguments: [trackId]),
                      let json: String = row["extended_metadata"] else { return nil }
                return ExtendedMetadata.fromJSON(json)?.musicBrainzTrackId
            }
        } catch {
            Logger.error("Failed to read recording MBID for track \(trackId): \(error)")
            return nil
        }
    }

    /// Node/edge counts of the stored graph (for the Settings status line). `nil` if empty.
    func relationsGraphStats() async -> RelationsGraphStats? {
        let path = relationsDBPath
        return await Task.detached(priority: .utility) {
            guard let store = try? RelationStore(path: path) else { return nil }
            let entities = (try? store.entityCount()) ?? 0
            let edges = (try? store.edgeCount()) ?? 0
            return entities == 0 && edges == 0 ? nil : RelationsGraphStats(entities: entities, edges: edges)
        }.value
    }

    // MARK: - Ingesting (online, rate-limited)

    /// Fetches the MusicBrainz relations for every recording MBID in the library and stores
    /// them in `relations.db`. Rate-limited to ~1 request/second (MusicBrainz policy), so a
    /// full library takes a while; progress and completion are surfaced through the
    /// NotificationManager. Idempotent — running it again refreshes/extends the graph.
    func ingestRelations() async {
        // Only one run at a time (two writers on the same file would conflict).
        let canStart = await MainActor.run { () -> Bool in
            guard !Self.relationsIngestRunning else { return false }
            Self.relationsIngestRunning = true
            return true
        }
        guard canStart else { return }
        defer { Task { @MainActor in Self.relationsIngestRunning = false } }

        let mbids = await libraryRecordingMBIDs()
        guard !mbids.isEmpty else {
            await MainActor.run {
                NotificationManager.shared.addMessage(
                    .info, String(localized: "No MusicBrainz IDs found in your library."))
            }
            return
        }

        await MainActor.run {
            NotificationManager.shared.startActivity(String(localized: "Loading MusicBrainz relationships…"))
        }

        let path = relationsDBPath
        let report = await Task.detached(priority: .utility) { () -> IngestReport? in
            guard let store = try? RelationStore(path: path) else { return nil }
            // BPMKit's default contact already identifies Musicae in the User-Agent, as
            // MusicBrainz requires — About.appWebsite still points at the Petrichor origin.
            let client = MusicBrainzClient()
            let ingestor = RelationIngestor(client: client, store: store)
            return await ingestor.ingest(recordingMBIDs: mbids, enrichReleases: true) { progress in
                Task { @MainActor in
                    let detail = progress.phase == "release"
                        ? String(localized: "Releases")
                        : String(localized: "Recordings")
                    NotificationManager.shared.updateActivityProgress(
                        current: progress.done, total: progress.total, detail: detail)
                }
            }
        }.value

        await MainActor.run {
            NotificationManager.shared.stopActivity()
            if let report {
                NotificationManager.shared.addMessage(
                    .info,
                    String(localized: "MusicBrainz relationships loaded: \(report.recordingsFetched) recordings, \(report.releasesEnriched) releases."))
            } else {
                NotificationManager.shared.addMessage(
                    .error, String(localized: "Could not load MusicBrainz relationships."))
            }
        }
    }

    /// The library's unique, valid recording MBIDs, read from the already-open main DB (not
    /// a second connection) — the reliable source Musicae's tag readers already populated.
    private func libraryRecordingMBIDs() async -> [String] {
        do {
            return try await dbQueue.read { db -> [String] in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT extended_metadata FROM tracks WHERE extended_metadata IS NOT NULL AND is_duplicate = 0")
                var mbids: [String] = []
                var seen = Set<String>()
                for row in rows {
                    guard let json: String = row["extended_metadata"],
                          let mbid = ExtendedMetadata.fromJSON(json)?.musicBrainzTrackId,
                          !mbid.isEmpty, UUID(uuidString: mbid) != nil,
                          seen.insert(mbid).inserted else { continue }
                    mbids.append(mbid)
                }
                return mbids
            }
        } catch {
            Logger.error("Failed to collect library recording MBIDs: \(error)")
            return []
        }
    }
}
