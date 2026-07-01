//
//  DatabaseManager class extension
//  Musicae
//
//  Smart playlist query builder for fetching tracks from database
//  based on Smart Playlist criteria
//

import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Normalized-table need detection

    /// Whether evaluating these rules requires the normalized Artists table. Artist matching
    /// now resolves against the denormalized column in all cases, so this never requires the
    /// fetch; kept as a gate for clarity/future use.
    func criteriaNeedsArtists(_ criteria: SmartPlaylistCriteria) -> Bool {
        false
    }

    /// Whether evaluating these rules requires the normalized Genres table.
    /// Genre matching always resolves against the denormalized column, so this is only
    /// kept as a gate for clarity/future use; it currently never requires the fetch.
    func criteriaNeedsGenres(_ criteria: SmartPlaylistCriteria) -> Bool {
        false
    }

    // MARK: - Smart Playlist Query Builder

    /// The filtered (not yet sorted or limited) track query for a smart playlist's criteria.
    /// Shared by the track-fetch and count paths so the filter logic lives in one place.
    func smartPlaylistFilteredQuery(
        _ criteria: SmartPlaylistCriteria,
        artists: [Artist],
        genres: [Genre],
        db: Database
    ) throws -> QueryInterfaceRequest<Track> {
        var query = applyDuplicateFilter(Track.all())

        // Rules on the computed axes live in a separate table; join it once (optionally,
        // so tracks without a fingerprint survive as NULLs and never false-match) and
        // load the library-relative energy scale only when an energy rule needs it.
        var fingerprintAlias: TableAlias<ComputedFingerprint>?
        var energyStats: FingerprintEnergyStats?
        if criteriaNeedsFingerprints(criteria) {
            let alias = TableAlias<ComputedFingerprint>()
            query = query.joining(optional: Track.computedFingerprint.aliased(alias))
            fingerprintAlias = alias
            if criteriaNeedsEnergy(criteria) {
                energyStats = try loadFingerprintEnergyStats(db)
            }
        }

        if let whereClause = buildWhereClause(
            for: criteria,
            artists: artists,
            genres: genres,
            fingerprintAlias: fingerprintAlias,
            energyStats: energyStats
        ) {
            query = query.filter(whereClause)
        }
        return query
    }

    /// Count tracks matching a criteria (honoring its limit) within an already-open read.
    func countSmartPlaylistTracks(
        _ criteria: SmartPlaylistCriteria,
        artists: [Artist],
        genres: [Genre],
        db: Database
    ) throws -> Int {
        let query = try smartPlaylistFilteredQuery(criteria, artists: artists, genres: genres, db: db)
        if let limit = criteria.limit {
            return try query.limit(limit).fetchCount(db)
        }
        return try query.fetchCount(db)
    }

    /// Count how many library tracks match a criteria's rules, ignoring any limit. Used by
    /// the editor's live "Matches N songs" footer to convey how selective the rules are
    /// (the limit is a separate, explicit cap). Opens its own read.
    func countMatchesForCriteria(_ criteria: SmartPlaylistCriteria) async -> Int {
        do {
            return try await dbQueue.read { db in
                let artists = self.criteriaNeedsArtists(criteria) ? try Artist.fetchAll(db) : []
                let genres = self.criteriaNeedsGenres(criteria) ? try Genre.fetchAll(db) : []
                return try self.smartPlaylistFilteredQuery(criteria, artists: artists, genres: genres, db: db).fetchCount(db)
            }
        } catch {
            Logger.error("Failed to count smart playlist matches: \(error)")
            return 0
        }
    }

    /// Build and run a smart playlist's full track query (filter, sort, limit, artwork) within
    /// an already-open read, loading the normalized tables only when a rule needs them.
    private func fetchSmartPlaylistTracks(for criteria: SmartPlaylistCriteria, db: Database) throws -> [Track] {
        let artists = criteriaNeedsArtists(criteria) ? try Artist.fetchAll(db) : []
        let genres = criteriaNeedsGenres(criteria) ? try Genre.fetchAll(db) : []

        var query = try smartPlaylistFilteredQuery(criteria, artists: artists, genres: genres, db: db)
        query = applySorting(to: query, criteria: criteria)
        if let limit = criteria.limit {
            query = query.limit(limit)
        }

        var tracks = try query.fetchAll(db)
        try populateAlbumArtworkForTracks(&tracks, db: db)
        return tracks
    }

    /// Build and execute a database query for a smart playlist
    func getTracksForSmartPlaylist(_ playlist: Playlist) async throws -> [Track] {
        guard playlist.type == .smart,
              let criteria = playlist.smartCriteria else {
            return []
        }

        return try await dbQueue.read { db in
            try self.fetchSmartPlaylistTracks(for: criteria, db: db)
        }
    }

    /// Get tracks for a smart playlist synchronously (for use in pinned items)
    func getTracksForSmartPlaylistSync(_ playlist: Playlist) -> [Track] {
        guard playlist.type == .smart,
              let criteria = playlist.smartCriteria else {
            return []
        }

        do {
            return try dbQueue.read { db in
                try self.fetchSmartPlaylistTracks(for: criteria, db: db)
            }
        } catch {
            Logger.error("Failed to get tracks for smart playlist '\(playlist.name)': \(error)")
            return []
        }
    }

    /// Build WHERE clause from smart playlist criteria
    internal func buildWhereClause(
        for criteria: SmartPlaylistCriteria,
        artists: [Artist],
        genres: [Genre],
        fingerprintAlias: TableAlias<ComputedFingerprint>?,
        energyStats: FingerprintEnergyStats?
    ) -> SQLExpression? {
        let expressions = criteria.rules.compactMap { rule in
            buildExpression(
                for: rule,
                artists: artists,
                genres: genres,
                fingerprintAlias: fingerprintAlias,
                energyStats: energyStats
            )
        }
        
        guard !expressions.isEmpty else { return nil }
        
        switch criteria.matchType {
        case .all:
            // AND all conditions together
            guard let first = expressions.first else { return nil }
            return expressions.dropFirst().reduce(first) { result, expr in
                result && expr
            }
        case .any:
            // OR all conditions together
            guard let first = expressions.first else { return nil }
            return expressions.dropFirst().reduce(first) { result, expr in
                result || expr
            }
        }
    }
    
    /// Build SQL expression for a single rule
    private func buildExpression(
        for rule: SmartPlaylistCriteria.Rule,
        artists: [Artist],
        genres: [Genre],
        fingerprintAlias: TableAlias<ComputedFingerprint>?,
        energyStats: FingerprintEnergyStats?
    ) -> SQLExpression? {
        switch rule.field {
        case "isFavorite":
            return buildBooleanExpression(column: Track.Columns.isFavorite, rule: rule)
            
        case "playCount":
            return buildNumericExpression(column: Track.Columns.playCount, rule: rule)
            
        case "lastPlayedDate":
            return buildDateExpression(column: Track.Columns.lastPlayedDate, rule: rule)
            
        case "dateAdded":
            return buildDateExpression(column: Track.Columns.dateAdded, rule: rule)
            
        case "title":
            return buildStringExpression(column: Track.Columns.title, rule: rule)
            
        case "artist":
            return buildArtistExpression(rule: rule, artists: artists)
            
        case "album":
            return buildStringExpression(column: Track.Columns.album, rule: rule)
            
        case "albumArtist":
            return buildStringExpression(column: Track.Columns.albumArtist, rule: rule)
            
        case "genre":
            return buildGenreExpression(rule: rule, genres: genres)
            
        case "year":
            return buildYearExpression(column: Track.Columns.year, rule: rule)
            
        case "composer":
            return buildComposerExpression(rule: rule, artists: artists)

        case "duration":
            return buildNumericExpression(column: Track.Columns.duration, rule: rule)

        case "trackNumber":
            return buildNumericExpression(column: Track.Columns.trackNumber, rule: rule)

        case "discNumber":
            return buildNumericExpression(column: Track.Columns.discNumber, rule: rule)

        case "filename":
            return buildStringExpression(column: Track.Columns.filename, rule: rule)

        case "calculatedBpm":
            // Joined from track_fingerprints; NULL for tracks without a fingerprint,
            // which SQL comparisons treat as non-matching (the honest behavior).
            guard let fingerprintAlias = fingerprintAlias else { return nil }
            return buildFingerprintNumericExpression(
                fingerprintAlias[ComputedFingerprint.Columns.calculatedBpm], rule: rule
            )

        case "energy":
            // Library-relative score; without stats (empty fingerprint set) there is no
            // honest match, so the rule contributes nothing.
            guard let fingerprintAlias = fingerprintAlias, let energyStats = energyStats else { return nil }
            return buildEnergyExpression(fingerprintAlias: fingerprintAlias, stats: energyStats, rule: rule)

        case "mixClass":
            guard let fingerprintAlias = fingerprintAlias else { return nil }
            switch rule.condition {
            case .equals:
                return fingerprintAlias[ComputedFingerprint.Columns.mixClass] == rule.value
            default:
                return nil
            }

        default:
            Logger.warning("Unsupported smart playlist field: \(rule.field)")
            return nil
        }
    }
    
    // MARK: - Helper Methods
    
    /// Build LIKE pattern based on condition
    private func buildLikePattern(for value: String, condition: SmartPlaylistCriteria.Condition) -> String {
        switch condition {
        case .contains:
            return "%\(value)%"
        case .startsWith:
            return "\(value)%"
        case .endsWith:
            return "%\(value)"
        default:
            return "%\(value)%"
        }
    }
    
    // MARK: - Expression Builders
    
    private func buildBooleanExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        let value = rule.value.lowercased() == "true"
        
        switch rule.condition {
        case .equals:
            return column == value
        default:
            return nil
        }
    }
    
    private func buildStringExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        switch rule.condition {
        case .equals:
            // Case-insensitive exact match using COLLATE NOCASE
            return column.collating(.nocase) == rule.value
        case .contains, .startsWith, .endsWith:
            // Case-insensitive pattern matching
            let pattern = buildLikePattern(for: rule.value, condition: rule.condition)
            return column.collating(.nocase).like(pattern)
        default:
            return nil
        }
    }
    
    private func buildNumericExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        guard let numericValue = Double(rule.value) else { return nil }

        switch rule.condition {
        case .equals:
            // Match the whole integer unit so a fractional-second duration still matches a
            // "M:SS" rule; for integer columns (play count, track/disc number) this is exact.
            return column >= numericValue && column < numericValue + 1
        case .greaterThan:
            return column > numericValue
        case .greaterThanOrEqual:
            return column >= numericValue
        case .lessThan:
            return column < numericValue
        case .lessThanOrEqual:
            return column <= numericValue
        default:
            return nil
        }
    }
    
    private func buildDateExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        // Handle "Xdays" format for relative dates
        if rule.value.hasSuffix("days") {
            let daysString = rule.value.replacingOccurrences(of: "days", with: "")
            guard let days = Int(daysString) else { return nil }
            
            let cutoffDate = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
            
            switch rule.condition {
            case .greaterThan:
                // For "in the last X days", we want dates greater than the cutoff
                return column != nil && column > cutoffDate
            case .lessThan:
                return column != nil && column < cutoffDate
            default:
                return nil
            }
        }
        
        // Handle absolute calendar dates ("yyyy-MM-dd"), matching by day in the local
        // calendar so the stored time-of-day is ignored.
        if let day = SmartPlaylistDate.date(from: rule.value) {
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: day)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }

            switch rule.condition {
            case .equals:
                // "on" that day
                return column != nil && column >= startOfDay && column < nextDay
            case .greaterThan:
                // "after" that day (strictly later than the whole day)
                return column != nil && column >= nextDay
            case .lessThan:
                // "before" the start of that day
                return column != nil && column < startOfDay
            default:
                return nil
            }
        }

        return nil
    }
    
    private func buildYearExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        // Year is stored as text. Exact match is a plain string compare, but greater/less
        // must compare numerically: a lexicographic compare would match non-numeric years
        // like "Unknown Year" (which sorts after digits). CAST makes the compare numeric and
        // turns non-numeric years into 0, which we exclude.
        switch rule.condition {
        case .equals:
            return column == rule.value
        case .greaterThan, .lessThan:
            guard let yearValue = Int(rule.value) else { return nil }
            let numericYear = cast(column, as: .integer)
            if rule.condition == .greaterThan {
                return numericYear > yearValue
            } else {
                return numericYear > 0 && numericYear < yearValue
            }
        default:
            return buildStringExpression(column: column, rule: rule)
        }
    }
    
    // MARK: - Normalized Table Expressions
    
    private func buildArtistExpression(rule: SmartPlaylistCriteria.Rule, artists: [Artist]) -> SQLExpression? {
        // Match against the denormalized artist column. Querying the normalized track_artists
        // table here would need a raw SQL literal subquery, so we accept the same limitation
        // as genre/composer matching and compare the track's own artist string.
        switch rule.condition {
        case .equals:
            return Track.Columns.artist.collating(.nocase) == rule.value
        case .contains, .startsWith, .endsWith:
            let pattern = buildLikePattern(for: rule.value, condition: rule.condition)
            return Track.Columns.artist.collating(.nocase).like(pattern)
        default:
            return buildStringExpression(column: Track.Columns.artist, rule: rule)
        }
    }
    
    private func buildGenreExpression(rule: SmartPlaylistCriteria.Rule, genres: [Genre]) -> SQLExpression? {
        switch rule.condition {
        case .equals:
            // Find matching genre by exact name
            let matchingGenreIds = genres.compactMap { genre -> Int64? in
                if genre.name == rule.value {
                    return genre.id
                }
                return nil
            }
            
            if !matchingGenreIds.isEmpty {
                // For now, fall back to denormalized column
                // This is because we can't easily create complex subqueries without SQL literals
                return Track.Columns.genre.collating(.nocase) == rule.value
            }
            
            // Fall back to denormalized column
            return Track.Columns.genre.collating(.nocase) == rule.value
            
        case .contains, .startsWith, .endsWith:
            // For partial matching
            let pattern = buildLikePattern(for: rule.value, condition: rule.condition)
            
            // Use denormalized column for genre pattern matching
            return Track.Columns.genre.collating(.nocase).like(pattern)
            
        default:
            return buildStringExpression(column: Track.Columns.genre, rule: rule)
        }
    }
    
    private func buildComposerExpression(rule: SmartPlaylistCriteria.Rule, artists: [Artist]) -> SQLExpression? {
        // For composer, we'll primarily use the denormalized column
        // since the normalized data is in track_artists with role='composer'
        // and we can't easily query that without SQL literals
        buildStringExpression(column: Track.Columns.composer, rule: rule)
    }
    
    // MARK: - Sorting
    
    private func applySorting(to query: QueryInterfaceRequest<Track>, criteria: SmartPlaylistCriteria) -> QueryInterfaceRequest<Track> {
        guard let sortBy = criteria.sortBy else { return query }
        
        let ascending = criteria.sortAscending
        
        switch sortBy {
        case "title":
            return ascending ? query.order(Track.Columns.title) : query.order(Track.Columns.title.desc)
        case "artist":
            return ascending ? query.order(Track.Columns.artist) : query.order(Track.Columns.artist.desc)
        case "album":
            return ascending ? query.order(Track.Columns.album) : query.order(Track.Columns.album.desc)
        case "playCount":
            return ascending ? query.order(Track.Columns.playCount) : query.order(Track.Columns.playCount.desc)
        case "lastPlayedDate":
            // Handle nil dates by treating them as distant past/future
            let nilDate = ascending ? Date.distantPast : Date.distantFuture
            return ascending
                ? query.order(Track.Columns.lastPlayedDate ?? nilDate)
                : query.order((Track.Columns.lastPlayedDate ?? nilDate).desc)
        case "dateAdded":
            return ascending ? query.order(Track.Columns.dateAdded) : query.order(Track.Columns.dateAdded.desc)
        case "duration":
            return ascending ? query.order(Track.Columns.duration) : query.order(Track.Columns.duration.desc)
        case "year":
            return ascending ? query.order(Track.Columns.year) : query.order(Track.Columns.year.desc)
        case "genre":
            return ascending ? query.order(Track.Columns.genre) : query.order(Track.Columns.genre.desc)
        case "trackNumber":
            return ascending ? query.order(Track.Columns.trackNumber) : query.order(Track.Columns.trackNumber.desc)
        case "discNumber":
            return ascending ? query.order(Track.Columns.discNumber) : query.order(Track.Columns.discNumber.desc)
        case "filename":
            return ascending ? query.order(Track.Columns.filename) : query.order(Track.Columns.filename.desc)
        default:
            return query
        }
    }

    // MARK: - Computed Fingerprint Axes (#16)

    /// Rule fields that live in `track_fingerprints` and therefore require the join.
    private static let fingerprintFields: Set<String> = ["calculatedBpm", "energy", "mixClass"]

    /// Whether any rule filters on a computed-fingerprint axis (needs the optional join).
    func criteriaNeedsFingerprints(_ criteria: SmartPlaylistCriteria) -> Bool {
        criteria.rules.contains { Self.fingerprintFields.contains($0.field) }
    }

    /// Whether any rule filters on the library-relative energy score (needs the min/max stats).
    private func criteriaNeedsEnergy(_ criteria: SmartPlaylistCriteria) -> Bool {
        criteria.rules.contains { $0.field == "energy" }
    }

    /// Per-axis min/max across all fingerprints, for the 0…1 energy normalization. `nil`
    /// when no fingerprints exist yet. Loudness/bass/dynamics are NOT NULL columns (their
    /// min/max are non-null once any row exists); BPM can be entirely null.
    struct FingerprintEnergyStats {
        let minLoud: Double, maxLoud: Double
        let minBass: Double, maxBass: Double
        let minDyn: Double, maxDyn: Double
        let minBpm: Double?, maxBpm: Double?
    }

    private func loadFingerprintEnergyStats(_ db: Database) throws -> FingerprintEnergyStats? {
        let sql = """
            SELECT MIN(rms_loudness_db) AS min_loud, MAX(rms_loudness_db) AS max_loud,
                   MIN(bass_ratio) AS min_bass, MAX(bass_ratio) AS max_bass,
                   MIN(dynamic_range_db) AS min_dyn, MAX(dynamic_range_db) AS max_dyn,
                   MIN(calculated_bpm) AS min_bpm, MAX(calculated_bpm) AS max_bpm
            FROM track_fingerprints
            """
        // With zero rows every aggregate is NULL, so a nil loudness means "no fingerprints".
        guard let row = try Row.fetchOne(db, sql: sql),
              let minLoud = row["min_loud"] as Double? else {
            return nil
        }
        return FingerprintEnergyStats(
            minLoud: minLoud, maxLoud: row["max_loud"],
            minBass: row["min_bass"], maxBass: row["max_bass"],
            minDyn: row["min_dyn"], maxDyn: row["max_dyn"],
            minBpm: row["min_bpm"], maxBpm: row["max_bpm"]
        )
    }

    /// Numeric comparison against a (nullable) joined fingerprint expression. Mirrors
    /// `buildNumericExpression`; a NULL column yields a NULL (non-matching) comparison, so
    /// tracks without a fingerprint never match.
    private func buildFingerprintNumericExpression(
        _ expression: SQLExpression,
        rule: SmartPlaylistCriteria.Rule
    ) -> SQLExpression? {
        guard let value = Double(rule.value) else { return nil }
        switch rule.condition {
        case .equals:
            return expression >= value && expression < value + 1
        case .greaterThan:
            return expression > value
        case .greaterThanOrEqual:
            return expression >= value
        case .lessThan:
            return expression < value
        case .lessThanOrEqual:
            return expression <= value
        default:
            return nil
        }
    }

    /// Threshold comparison against the library-relative energy score (UI value 0…100).
    private func buildEnergyExpression(
        fingerprintAlias: TableAlias<ComputedFingerprint>,
        stats: FingerprintEnergyStats,
        rule: SmartPlaylistCriteria.Rule
    ) -> SQLExpression? {
        guard let percent = Double(rule.value) else { return nil }
        let threshold = percent / 100.0
        let energy = energySQLExpression(fingerprintAlias: fingerprintAlias, stats: stats)
        switch rule.condition {
        case .greaterThan:
            return energy > threshold
        case .greaterThanOrEqual:
            return energy >= threshold
        case .lessThan:
            return energy < threshold
        case .lessThanOrEqual:
            return energy <= threshold
        default:
            return nil
        }
    }

    /// The energy score as a SQL expression: loud + fast + bass-heavy + low-dynamics, each
    /// min/max-normalized to 0…1 and equally weighted — the same formula as
    /// `BPMKit.FingerprintDataset.energy`, evaluated against the joined fingerprint row.
    private func energySQLExpression(fingerprintAlias fp: TableAlias<ComputedFingerprint>, stats: FingerprintEnergyStats) -> SQLExpression {
        // (value - min)/(max - min); a degenerate range collapses to a neutral 0.5,
        // matching BPMKit's MinMax.normalize.
        func norm(_ expression: SQLExpression, _ min: Double, _ max: Double) -> SQLExpression {
            max > min ? (expression - min) / (max - min) : 0.5.sqlExpression
        }
        let loud = norm(fp[ComputedFingerprint.Columns.rmsLoudnessDb], stats.minLoud, stats.maxLoud)
        let bass = norm(fp[ComputedFingerprint.Columns.bassRatio], stats.minBass, stats.maxBass)
        let dynamic = norm(fp[ComputedFingerprint.Columns.dynamicRangeDb], stats.minDyn, stats.maxDyn)

        let fast: SQLExpression
        if let minBpm = stats.minBpm, let maxBpm = stats.maxBpm, maxBpm > minBpm {
            // BPMKit substitutes the band minimum for tracks without a detected tempo.
            fast = ((fp[ComputedFingerprint.Columns.calculatedBpm] ?? minBpm) - minBpm) / (maxBpm - minBpm)
        } else {
            fast = 0.5.sqlExpression
        }

        return (loud + fast + bass + (1.0 - dynamic)) / 4.0
    }
}
