//
// DatabaseManager class extension
//
// "Similar tracks" (#17): the filter-based neighbour search from Phase 3 brought into
// the app. Reuses BPMKit's `FingerprintDataset.neighbours` (weighted by era, energy,
// mix class and length) over the computed fingerprints in `musicae.db` — no acoustic
// guesswork, just the honest filter distance.
//

import BPMKit
import Foundation
import GRDB

extension DatabaseManager {
    /// Outcome of a neighbour search, so the UI can tell "not analyzed yet" apart from
    /// "analyzed, but nothing nearby" — the anchor is treated honestly, never guessed.
    enum SimilarTracksResult {
        /// The anchor has no computed fingerprint yet; show a hint, not a bogus list.
        case anchorNotAnalyzed
        /// Neighbours ordered by ascending distance (closest first); may be empty.
        case neighbors([Track])
    }

    /// Finds the tracks most similar to `anchorId` using BPMKit's weighted distance over
    /// every non-duplicate fingerprint in the library.
    func similarTracks(toTrackId anchorId: Int64, limit: Int = 25) async -> SimilarTracksResult {
        do {
            return try await dbQueue.read { db in
                // Load every fingerprint joined to its track facts (year/duration/etc.),
                // the shape BPMKit's dataset needs. Personal-library scale — one pass in memory.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT t.id AS track_id, t.path AS path, t.title AS title, t.artist AS artist,
                           t.album AS album, t.year AS year, t.duration AS duration,
                           f.calculated_bpm AS bpm, f.bpm_confidence AS conf,
                           f.rms_loudness_db AS loud, f.dynamic_range_db AS dyn,
                           f.spectral_brightness_hz AS bright, f.bass_ratio AS bass,
                           f.mix_version AS mix, f.analyzed_at AS analyzed
                    FROM track_fingerprints f
                    JOIN tracks t ON t.id = f.track_id
                    WHERE t.is_duplicate = 0
                    """)

                var fingerprints: [TrackFingerprint] = []
                fingerprints.reserveCapacity(rows.count)
                var trackIdByPath: [String: Int64] = [:]
                var anchorPath: String?

                for row in rows {
                    let trackId: Int64 = row["track_id"]
                    let path: String = row["path"]
                    let yearText: String = row["year"]
                    let axes = AudioAxes(
                        rmsLoudnessDb: row["loud"],
                        dynamicRangeDb: row["dyn"],
                        spectralBrightnessHz: row["bright"],
                        bassRatio: row["bass"]
                    )
                    fingerprints.append(TrackFingerprint(
                        path: path,
                        title: row["title"],
                        artist: row["artist"],
                        album: row["album"],
                        year: Self.parseYear(yearText),
                        durationSeconds: row["duration"],
                        bpm: row["bpm"],
                        bpmConfidence: row["conf"],
                        axes: axes,
                        mixVersion: row["mix"],
                        analyzedAt: row["analyzed"]
                    ))
                    trackIdByPath[path] = trackId
                    if trackId == anchorId { anchorPath = path }
                }

                // Anchor without a fingerprint → honest hint, not a guessed list.
                guard let anchorPath = anchorPath,
                      let anchor = fingerprints.first(where: { $0.path == anchorPath }) else {
                    return .anchorNotAnalyzed
                }

                let dataset = FingerprintDataset(tracks: fingerprints)
                let neighbours = dataset.neighbors(of: anchor, limit: limit)
                let orderedIds = neighbours.compactMap { trackIdByPath[$0.track.path] }

                // Load the app Track objects and restore the distance ordering (an IN
                // fetch returns them in DB order).
                let fetched = try Track.filter(orderedIds.contains(Track.Columns.trackId)).fetchAll(db)
                let byId = Dictionary(
                    fetched.compactMap { track in track.trackId.map { ($0, track) } },
                    uniquingKeysWith: { first, _ in first }
                )
                var ordered = orderedIds.compactMap { byId[$0] }
                try self.populateAlbumArtworkForTracks(&ordered, db: db)
                return .neighbors(ordered)
            }
        } catch {
            Logger.error("Failed to compute similar tracks for \(anchorId): \(error)")
            return .neighbors([])
        }
    }

    /// Tolerant year parse: `tracks.year` is free text ("1995", "1995-06-01", "Unknown
    /// Year"). Takes the leading 4-digit run, else nil (BPMKit gives an unknown year a
    /// neutral, non-maximal era penalty).
    private static func parseYear(_ raw: String) -> Int? {
        let leading = raw.trimmingCharacters(in: .whitespaces).prefix(4)
        guard leading.count == 4 else { return nil }
        return Int(leading)
    }
}
