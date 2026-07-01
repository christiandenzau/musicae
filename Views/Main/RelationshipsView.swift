import BPMKit
import SwiftUI

/// Identifiable request so `.sheet(item:)` can present the relations view for a specific
/// anchor track.
struct RelationshipsRequest: Identifiable {
    let id = UUID()
    let anchorTrackId: Int64
    let anchorTitle: String
}

/// Shows the MusicBrainz relationship thread of a track (#18): the walkable graph from
/// Phase 4 (`RelationStore`/`RelationGraph`) begun at the track's recording MBID — appears-on
/// → release → release-group, remix-of, cover-of. Every honest case has its own state: no
/// recording MBID, graph not loaded yet, or no data for this recording — never a guessed or
/// misleading list.
struct RelationshipsView: View {
    let request: RelationshipsRequest

    @EnvironmentObject var libraryManager: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var result: DatabaseManager.RelationsResult?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 640, height: 560)
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
                Text("Relationships")
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
        switch result {
        case nil:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .noMBID:
            emptyState(
                icon: "link.badge.plus",
                title: String(localized: "No MusicBrainz link"),
                message: String(localized: "This track has no MusicBrainz recording ID in its tags, so there's nothing to look up."))

        case .noGraph:
            emptyState(
                icon: "network.slash",
                title: String(localized: "Relationships not loaded yet"),
                message: String(localized: "Load them once from Settings → Integrations to see how this track connects to its releases and remixes."))

        case .anchorMissing:
            emptyState(
                icon: "questionmark.circle",
                title: String(localized: "No relationship data for this track"),
                message: String(localized: "MusicBrainz returned nothing for this recording, or the load hasn't reached it yet."))

        case let .thread(anchor, steps):
            if steps.isEmpty {
                emptyState(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: String(localized: "No stored relationships"),
                    message: String(localized: "This recording is in the graph but has no outgoing relationships."))
            } else {
                thread(anchor: anchor, steps: steps)
            }
        }
    }

    /// The anchor recording followed by its outgoing steps, indented by depth — the
    /// "walkable thread" (appears-on → release → release-group, …).
    private func thread(anchor: GraphNode, steps: [RelationGraph.Step]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                anchorRow(anchor)
                    .padding(.bottom, 4)
                Divider()
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    stepRow(step)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rows

    private func anchorRow(_ node: GraphNode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.icon(for: node.kind))
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title ?? request.anchorTitle)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle = Self.subtitle(for: node) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func stepRow(_ step: RelationGraph.Step) -> some View {
        // Depth starts at 1 for the anchor's direct relations; deeper steps indent further.
        let indent = CGFloat(max(0, step.depth - 1)) * 22

        return HStack(alignment: .top, spacing: 8) {
            if indent > 0 {
                Color.clear.frame(width: indent, height: 1)
            }
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 14)
                .padding(.top, 3)

            Image(systemName: Self.icon(for: step.edge.targetKind))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.localizedRelation(step.edge.relation))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(step.target?.title ?? String(localized: "Unknown"))
                    .font(.system(size: 12, weight: .medium))
                if let subtitle = step.target.flatMap(Self.subtitle(for:)) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
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
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Load

    private func load() {
        Task {
            let outcome = await libraryManager.databaseManager.relationshipThread(forTrackId: request.anchorTrackId)
            await MainActor.run { result = outcome }
        }
    }

    // MARK: - Presentation helpers

    /// An SF Symbol for each MusicBrainz entity kind.
    private static func icon(for kind: MBEntityKind) -> String {
        switch kind {
        case .recording: return "waveform"
        case .release: return "opticaldisc"
        case .releaseGroup: return "rectangle.stack"
        case .work: return "doc.text"
        case .artist: return "person"
        case .label: return "tag"
        case .unknown: return "questionmark.circle"
        }
    }

    /// The secondary line for a node — artist, year, label/type — mirroring the CLI's
    /// `describeNode`, but only the parts that are actually known.
    private static func subtitle(for node: GraphNode) -> String? {
        var parts: [String] = []
        if let artist = node.artist { parts.append(artist) }
        if let year = node.year { parts.append(String(year)) }
        if let label = node.label {
            parts.append(label)
        } else if let type = node.primaryType {
            parts.append(type)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Reads the common BPMKit edge labels in the UI language; unknown labels stay raw.
    private static func localizedRelation(_ raw: String) -> String {
        switch raw {
        case "appears on": return String(localized: "appears on")
        case "release of": return String(localized: "release of")
        case "remix of": return String(localized: "remix of")
        case "has remix": return String(localized: "has remix")
        case "cover of": return String(localized: "cover of")
        case "covered by": return String(localized: "covered by")
        case "edit of": return String(localized: "edit of")
        case "has edit": return String(localized: "has edit")
        case "samples": return String(localized: "samples")
        case "sampled by": return String(localized: "sampled by")
        default: return raw
        }
    }
}
