//
// RelationGraph.swift
//
// Das Domänenmodell des Beziehungsgraphen (Phase 4, #7) — netz- und formatfrei.
// Zwei Teile:
//
//   • Der **Builder** faltet eine rohe MusicBrainz-Antwort (`MusicBrainzModels`)
//     zu Knoten und Kanten. Genau hier, an einer Stelle, sitzt das Mapping vom
//     Draht-Format aufs Domänenmodell — reine, gegen Fixtures testbare Logik.
//   • Der **Graph** selbst ist eine geladene Menge Knoten + Kanten mit den zwei
//     Operationen, die den „begehbaren Faden" ausmachen: Nachbarn und ein
//     beschränktes Durchwandern (BFS).
//
// Bewusst ohne SQL und ohne URLSession: der Store (`RelationStore`) persistiert,
// der Client (`MusicBrainzClient`) holt — diese Datei rechnet nur.
//

import Foundation

// MARK: - Entitätsart

/// Die Art eines Knotens. Deckt die für die Testscheibe relevanten
/// MusicBrainz-Entitäten ab; alles Übrige fällt bewusst auf `.unknown`.
public enum MBEntityKind: String, Codable, Sendable, CaseIterable {
    case recording
    case release
    case releaseGroup = "release-group"
    case work
    case artist
    case label
    case unknown

    /// MusicBrainz' `target-type`-String → Art (tolerant).
    public static func from(targetType: String?) -> MBEntityKind {
        guard let raw = targetType?.lowercased() else { return .unknown }
        return MBEntityKind(rawValue: raw) ?? .unknown
    }
}

// MARK: - Knoten & Kante

/// Ein Knoten des Graphen: eine MusicBrainz-Entität mit gerade so viel Fakten,
/// wie der begehbare Faden zeigt (Jahr, Label, Typ der Veröffentlichung).
public struct GraphNode: Codable, Equatable, Sendable {
    public var mbid: String
    public var kind: MBEntityKind
    public var title: String?
    public var artist: String?
    public var year: Int?
    public var label: String?
    public var primaryType: String?   // Release-Gruppe: Album/Single/EP …

    public init(
        mbid: String,
        kind: MBEntityKind,
        title: String? = nil,
        artist: String? = nil,
        year: Int? = nil,
        label: String? = nil,
        primaryType: String? = nil
    ) {
        self.mbid = mbid
        self.kind = kind
        self.title = title
        self.artist = artist
        self.year = year
        self.label = label
        self.primaryType = primaryType
    }

    /// Spaltennamen in snake_case — der Store (`RelationStore`) heftet die
    /// GRDB-Konformität an; diese Datei bleibt bewusst SQL-frei.
    enum CodingKeys: String, CodingKey {
        case mbid, kind, title, artist, year, label
        case primaryType = "primary_type"
    }

    /// Vereint zwei Sichten desselben Knotens: gesetzte Fakten gewinnen gegenüber
    /// leeren. So darf ein späterer, reicherer Lookup (Label!) einen früher aus
    /// einer Kante angelegten Stummel ergänzen, ohne ihn zu überschreiben.
    public func merged(with other: GraphNode) -> GraphNode {
        GraphNode(
            mbid: mbid,
            kind: kind == .unknown ? other.kind : kind,
            title: title ?? other.title,
            artist: artist ?? other.artist,
            year: year ?? other.year,
            label: label ?? other.label,
            primaryType: primaryType ?? other.primaryType
        )
    }
}

/// Eine gerichtete Kante: von `sourceMBID` (das abgefragte Recording) zu
/// `targetMBID`, beschriftet mit der lesbaren Beziehung (z. B. „remix of",
/// „appears on"). Eine Kante pro (Quelle, Ziel, Beziehung).
public struct GraphEdge: Codable, Equatable, Sendable {
    public var sourceMBID: String
    public var targetMBID: String
    public var relation: String
    public var targetKind: MBEntityKind

    public init(sourceMBID: String, targetMBID: String, relation: String, targetKind: MBEntityKind) {
        self.sourceMBID = sourceMBID
        self.targetMBID = targetMBID
        self.relation = relation
        self.targetKind = targetKind
    }

    enum CodingKeys: String, CodingKey {
        case sourceMBID = "source_mbid"
        case targetMBID = "target_mbid"
        case relation
        case targetKind = "target_kind"
    }
}

// MARK: - Builder (Draht-Format → Graph)

/// Faltet MusicBrainz-Antworten zu Knoten und Kanten. Rein statisch, ohne
/// Zustand — dieselbe Antwort ergibt immer denselben Ausschnitt.
public enum RelationGraphBuilder {
    /// Der Ausschnitt aus *einem* Recording-Lookup: der Aufnahme-Knoten, alle
    /// Nachbar-Knoten (Releases, Remix-Vorlagen …) und die Kanten dazwischen.
    public struct Fragment: Equatable, Sendable {
        public var nodes: [GraphNode]
        public var edges: [GraphEdge]
        public init(nodes: [GraphNode] = [], edges: [GraphEdge] = []) {
            self.nodes = nodes
            self.edges = edges
        }
    }

    /// Zerlegt einen Recording-Lookup in seinen Graph-Ausschnitt:
    ///   • den Recording-Knoten (Jahr = `first-release-date`),
    ///   • je Release eine „appears on"-Kante zum Release-Knoten (Jahr = Datum),
    ///   • je Beziehung (Remix-von, Cover-von …) eine Kante zum Zielknoten.
    public static func fragment(from recording: MBRecording) -> Fragment {
        let artist = recording.artistCredit?.displayName
        let recordingNode = GraphNode(
            mbid: recording.id,
            kind: .recording,
            title: recording.title,
            artist: artist,
            year: year(fromDate: recording.firstReleaseDate)
        )

        var nodes = [recordingNode]
        var edges: [GraphEdge] = []

        // „Erscheint auf" — der Faden zur Maxi/zum Album.
        for release in recording.releases ?? [] {
            nodes.append(node(from: release))
            edges.append(GraphEdge(
                sourceMBID: recording.id,
                targetMBID: release.id,
                relation: "appears on",
                targetKind: .release
            ))
        }

        // Remix-von, Cover-von & Co.
        for relation in recording.relations ?? [] {
            guard let target = relation.target else { continue }
            let kind = MBEntityKind.from(targetType: relation.targetType)
            nodes.append(GraphNode(
                mbid: target.id,
                kind: kind,
                title: target.title,
                year: year(fromDate: target.firstReleaseDate)
            ))
            edges.append(GraphEdge(
                sourceMBID: recording.id,
                targetMBID: target.id,
                relation: relationLabel(type: relation.type, direction: relation.direction),
                targetKind: kind
            ))
        }

        return Fragment(nodes: nodes, edges: edges)
    }

    /// Der angereicherte Release-Knoten aus einem Release-Lookup — trägt Label
    /// und Release-Gruppe (das „Album"), die der Recording-Lookup nicht liefert.
    /// Gibt zusätzlich die Kante Release → Release-Gruppe zurück, falls vorhanden.
    public static func fragment(fromRelease release: MBRelease) -> Fragment {
        var nodes = [node(from: release)]
        var edges: [GraphEdge] = []
        if let group = release.releaseGroup {
            nodes.append(GraphNode(
                mbid: group.id,
                kind: .releaseGroup,
                title: group.title,
                year: year(fromDate: group.firstReleaseDate),
                primaryType: group.primaryType
            ))
            edges.append(GraphEdge(
                sourceMBID: release.id,
                targetMBID: group.id,
                relation: "release of",
                targetKind: .releaseGroup
            ))
        }
        return Fragment(nodes: nodes, edges: edges)
    }

    /// Ein Release-Knoten aus den (mal knappen, mal reichen) Release-Feldern.
    private static func node(from release: MBRelease) -> GraphNode {
        GraphNode(
            mbid: release.id,
            kind: .release,
            title: release.title,
            year: year(fromDate: release.date),
            label: release.labelInfo?.compactMap { $0.label?.name }.first,
            primaryType: release.releaseGroup?.primaryType
        )
    }
}

// MARK: - Lesbare Beziehung

/// Übersetzt MusicBrainz' `type` + `direction` in ein lesbares Kantenlabel. Die
/// Richtung ist ehrlich: „backward" heißt, die abgefragte Aufnahme ist das
/// *abgeleitete* Werk (das Remix, die Coverversion) — genau der Faden, den #7
/// sucht. Unbekannte Typen behalten ihren rohen Namen (mit Richtungspfeil).
public func relationLabel(type: String?, direction: String?) -> String {
    let base = (type ?? "related").lowercased()
    let backward = (direction ?? "").lowercased() == "backward"
    switch base {
    case "remix":            return backward ? "remix of" : "has remix"
    case "cover":            return backward ? "cover of" : "covered by"
    case "edit":             return backward ? "edit of" : "has edit"
    case "karaoke":          return backward ? "karaoke of" : "has karaoke"
    case "samples material": return backward ? "samples" : "sampled by"
    case "mashes up":        return backward ? "mashes up" : "mashed up in"
    case "medley":           return "medley of"
    default:                 return backward ? "\(base) (←)" : base
    }
}

// MARK: - Jahr aus MusicBrainz-Datum

/// Zieht das Jahr aus einem MusicBrainz-Datum („1993", „1993-09-06") — die erste
/// plausible vierstellige Jahreszahl (1900–2100). `nil`, wenn keine da ist.
public func year(fromDate string: String?) -> Int? {
    guard let string else { return nil }
    let characters = Array(string)
    var index = 0
    while index + 4 <= characters.count {
        let slice = characters[index..<index + 4]
        if slice.allSatisfy(\.isNumber), let value = Int(String(slice)), (1900...2100).contains(value) {
            return value
        }
        index += 1
    }
    return nil
}

// MARK: - Der begehbare Graph

/// Eine geladene Menge Knoten + Kanten mit den Operationen, die den Faden
/// begehbar machen. Reiner Wert, aus dem Store gefüllt oder direkt im Test.
public struct RelationGraph: Sendable {
    public let nodesByID: [String: GraphNode]
    public let edges: [GraphEdge]
    private let outgoing: [String: [GraphEdge]]

    public init(nodes: [GraphNode], edges: [GraphEdge]) {
        self.nodesByID = Dictionary(nodes.map { ($0.mbid, $0) }, uniquingKeysWith: { $0.merged(with: $1) })
        self.edges = edges
        self.outgoing = Dictionary(grouping: edges, by: \.sourceMBID)
    }

    public var nodes: [GraphNode] { Array(nodesByID.values) }
    public func node(_ mbid: String) -> GraphNode? { nodesByID[mbid] }

    /// Die von `mbid` ausgehenden Kanten, stabil sortiert (Beziehung, dann Ziel).
    public func neighbors(of mbid: String) -> [GraphEdge] {
        (outgoing[mbid] ?? []).sorted {
            ($0.relation, $0.targetMBID) < ($1.relation, $1.targetMBID)
        }
    }

    /// Ein Schritt beim Durchwandern: die Kante und der (falls bekannt) Zielknoten,
    /// plus die Tiefe ab dem Startknoten.
    public struct Step: Sendable {
        public let depth: Int
        public let edge: GraphEdge
        public let target: GraphNode?
    }

    /// Durchwandert den Graphen ab `start` in Breite bis `maxDepth`. Jeder Knoten
    /// wird nur einmal expandiert (kein Zyklus, keine Doppelung); die Reihenfolge
    /// ist deterministisch. Das ist der „begehbare Faden" der Testscheibe.
    public func walk(from start: String, maxDepth: Int = 2) -> [Step] {
        var visited: Set<String> = [start]
        var queue: [(mbid: String, depth: Int)] = [(start, 0)]
        var steps: [Step] = []
        var head = 0
        while head < queue.count {
            let (mbid, depth) = queue[head]
            head += 1
            guard depth < maxDepth else { continue }
            for edge in neighbors(of: mbid) {
                steps.append(Step(depth: depth + 1, edge: edge, target: nodesByID[edge.targetMBID]))
                if !visited.contains(edge.targetMBID) {
                    visited.insert(edge.targetMBID)
                    queue.append((edge.targetMBID, depth + 1))
                }
            }
        }
        return steps
    }
}
