import SwiftUI

/// Identifiable request so `.sheet(item:)` can present the similar-tracks view for a
/// specific anchor track.
struct SimilarTracksRequest: Identifiable {
    let id = UUID()
    let anchorTrackId: Int64
    let anchorTitle: String
}

/// Shows the tracks most similar to an anchor — the filter-distance neighbours from
/// Phase 3 (`FingerprintDataset.neighbors`: era, energy, mix class, length), #17 — in a
/// normal, playable `TrackTableView`. An anchor without a computed fingerprint gets an
/// honest hint instead of a guessed list.
struct SimilarTracksView: View {
    let request: SimilarTracksRequest

    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @Environment(\.dismiss) private var dismiss

    @State private var tracks: [Track] = []
    @State private var anchorNotAnalyzed = false
    @State private var isLoading = true
    // Empty so the neighbours keep their distance ordering (TrackTableView sorts entity
    // lists with `sorted(using:)`, which is stable for an empty comparator set). A column
    // click still lets the user re-sort afterwards.
    @State private var sortOrder: [KeyPathComparator<Track>] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 720, height: 560)
        .onAppear(perform: load)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Similar Tracks")
                    .font(.headline)
                Text(request.anchorTitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if anchorNotAnalyzed {
            emptyState(
                icon: "waveform.slash",
                title: String(localized: "Not analyzed yet"),
                message: String(localized: "This track has no computed fingerprint yet, so similar tracks can't be found.")
            )
        } else if tracks.isEmpty {
            emptyState(
                icon: Icons.musicNote,
                title: String(localized: "No similar tracks found"),
                message: String(localized: "No other analyzed tracks are close enough to suggest.")
            )
        } else {
            TrackView(
                tracks: tracks,
                selectedTrackID: .constant(nil),
                playlistID: nil,
                entityID: request.id,
                sortOrder: $sortOrder,
                onPlayTrack: { track in
                    // Play the neighbour with the whole similar list as its queue context.
                    playlistManager.playTrack(track, fromTracks: tracks)
                },
                contextMenuItems: { rowTracks, _ in
                    TrackContextMenu.createMenuItems(
                        for: rowTracks,
                        playlistManager: playlistManager,
                        currentContext: .library
                    )
                }
            )
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Load

    private func load() {
        Task {
            let result = await libraryManager.databaseManager.similarTracks(toTrackId: request.anchorTrackId)
            await MainActor.run {
                switch result {
                case .anchorNotAnalyzed:
                    anchorNotAnalyzed = true
                case .neighbors(let neighbours):
                    tracks = neighbours
                }
                isLoading = false
            }
        }
    }
}
