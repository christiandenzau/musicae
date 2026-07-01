//
// DatabaseManager class extension
//
// Resumable background run that computes the native audio fingerprint (BPMKit)
// for every track and persists it into `track_fingerprints`. Follows the same
// pattern as the other background migrations (offset progress, batched writes,
// activity notifications) and, like the `bpmdetect` CLI, analyzes a sliding
// window of tracks in parallel — decoding + FFT is CPU-bound.
//
// Honesty law: the estimated BPM lands in the separate fingerprint row and never
// overwrites the tagged `tracks.bpm`.
//

import BPMKit
import Foundation
import GRDB

extension DatabaseManager {
    static let fingerprintMigrationIdentifier = "v12_background_compute_fingerprints"

    private struct FingerprintProgress: Codable {
        let offset: Int
    }

    /// Computes and persists a `ComputedFingerprint` for every (non-duplicate)
    /// track. Resumable via the stored offset; idempotent via `INSERT OR REPLACE`.
    func computeTrackFingerprints(progress: String?) async {
        NotificationManager.shared.startActivity(String(localized: "Analyzing Audio..."))

        var resumeOffset = 0
        if let progress = progress,
           let data = progress.data(using: .utf8),
           let state = try? JSONDecoder().decode(FingerprintProgress.self, from: data) {
            resumeOffset = state.offset
            Logger.info("Resuming fingerprint analysis at offset \(resumeOffset)")
        }

        do {
            let totalTracks = try await dbQueue.read { db in
                try Track.filter(Track.Columns.isDuplicate == false).fetchCount(db)
            }

            guard totalTracks > 0 else {
                completeBackgroundMigration(Self.fingerprintMigrationIdentifier)
                NotificationManager.shared.stopActivity()
                Logger.info("No tracks to fingerprint")
                return
            }

            Logger.info("Computing fingerprints for \(totalTracks) tracks (resume offset \(resumeOffset))")

            try await Task.detached(priority: .utility) { [dbQueue, weak self] in
                guard let self = self else { return }

                let bpmEstimator = BPMEstimator()      // Eurodance band 120–150 by default
                let axesAnalyzer = AudioAxesAnalyzer()
                let analyzedAt = Date()
                let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
                let batchSize = 50

                var offset = resumeOffset
                var analyzed = 0
                var failed = 0

                while true {
                    // Copy the offset into an immutable value so the read closure
                    // stays @Sendable (no captured var) under strict concurrency.
                    // The closure returns Sendable tuples (not [Track]) across the
                    // await boundary, and the raw row count drives termination so a
                    // batch of id-less rows can never loop forever.
                    let batchOffset = offset
                    let (items, rowCount) = try await dbQueue.read { db -> ([(id: Int64, url: URL, title: String)], Int) in
                        let tracks = try Track
                            .filter(Track.Columns.isDuplicate == false)
                            .order(Track.Columns.trackId)
                            .limit(batchSize, offset: batchOffset)
                            .fetchAll(db)
                        let items = tracks.compactMap { track -> (id: Int64, url: URL, title: String)? in
                            guard let id = track.trackId else { return nil }
                            return (id, track.url, track.title)
                        }
                        return (items, tracks.count)
                    }
                    if rowCount == 0 { break }

                    let fingerprints = await Self.analyzeWindow(
                        items,
                        bpmEstimator: bpmEstimator,
                        axesAnalyzer: axesAnalyzer,
                        analyzedAt: analyzedAt,
                        maxConcurrent: maxConcurrent
                    )

                    if !fingerprints.isEmpty {
                        try await dbQueue.write { db in
                            for fingerprint in fingerprints {
                                try fingerprint.insert(db)
                            }
                        }
                    }

                    analyzed += fingerprints.count
                    failed += items.count - fingerprints.count
                    offset += rowCount

                    self.saveFingerprintProgress(offset: offset)
                    NotificationManager.shared.updateActivityProgress(
                        current: min(offset, totalTracks),
                        total: totalTracks
                    )
                }

                let failInfo = failed > 0 ? " (\(failed) skipped)" : ""
                Logger.info("Fingerprint analysis wrote \(analyzed) rows\(failInfo)")
            }.value

            completeBackgroundMigration(Self.fingerprintMigrationIdentifier)
            NotificationManager.shared.stopActivity()
            NotificationManager.shared.addMessage(.info, String(localized: "Audio analysis completed"))
            Logger.info("Fingerprint analysis completed")
        } catch {
            NotificationManager.shared.stopActivity()
            NotificationManager.shared.addMessage(.error, String(localized: "Failed to analyze audio"))
            Logger.error("Fingerprint analysis failed: \(error)")
        }
    }

    // MARK: - Analysis

    /// Analyzes one window of tracks with a sliding concurrency limit and returns
    /// the successfully computed fingerprints (undecodable files are dropped).
    /// Pure inputs only, so it never captures the (non-Sendable) manager.
    private static func analyzeWindow(
        _ items: [(id: Int64, url: URL, title: String)],
        bpmEstimator: BPMEstimator,
        axesAnalyzer: AudioAxesAnalyzer,
        analyzedAt: Date,
        maxConcurrent: Int
    ) async -> [ComputedFingerprint] {
        await withTaskGroup(of: ComputedFingerprint?.self) { group in
            var next = 0
            func schedule(_ index: Int) {
                let item = items[index]
                group.addTask {
                    analyzeTrack(
                        id: item.id,
                        url: item.url,
                        title: item.title,
                        bpmEstimator: bpmEstimator,
                        axesAnalyzer: axesAnalyzer,
                        analyzedAt: analyzedAt
                    )
                }
            }
            while next < min(maxConcurrent, items.count) { schedule(next); next += 1 }

            var collected: [ComputedFingerprint] = []
            for await result in group {
                if let result = result { collected.append(result) }
                if next < items.count { schedule(next); next += 1 }
            }
            return collected
        }
    }

    /// Decodes a file once and derives BPM + axes + mix version from it. Returns
    /// `nil` when the file cannot be decoded or is too short to analyze.
    private static func analyzeTrack(
        id: Int64,
        url: URL,
        title: String,
        bpmEstimator: BPMEstimator,
        axesAnalyzer: AudioAxesAnalyzer,
        analyzedAt: Date
    ) -> ComputedFingerprint? {
        guard let samples = try? AudioLoader.loadMonoSamples(url: url) else { return nil }
        let sampleRate = AudioLoader.defaultSampleRate
        guard let axes = axesAnalyzer.analyze(samples: samples, sampleRate: sampleRate) else { return nil }

        let bpm = bpmEstimator.estimate(samples: samples, sampleRate: sampleRate)
        let mixVersion = MixVersionParser.parse(title: title)

        return ComputedFingerprint(
            trackId: id,
            calculatedBpm: bpm?.bpm,
            bpmConfidence: bpm?.confidence,
            rmsLoudnessDb: axes.rmsLoudnessDb,
            dynamicRangeDb: axes.dynamicRangeDb,
            spectralBrightnessHz: axes.spectralBrightnessHz,
            bassRatio: axes.bassRatio,
            mixVersion: mixVersion,
            // Denormalized once here from the single classification source, so the
            // smart-playlist query can filter on it directly (#16).
            mixClass: MixClass.classify(mixVersion).rawValue,
            analyzedAt: analyzedAt
        )
    }

    // MARK: - Progress

    private func saveFingerprintProgress(offset: Int) {
        if let data = try? JSONEncoder().encode(FingerprintProgress(offset: offset)),
           let json = String(data: data, encoding: .utf8) {
            updateMigrationProgress(Self.fingerprintMigrationIdentifier, progress: json)
        }
    }
}
