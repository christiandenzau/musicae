//
// RelationStore.swift
//
// Persistiert den Beziehungsgraphen (Phase 4, #7) über GRDB — dieselbe
// Persistenzschicht wie die Musicae-App, aber in einer **eigenen** Datei mit
// **eigenen** Tabellen (`mb_entities`, `mb_relations`): kein Eingriff in die
// bestehenden Musicae- oder Fingerprint-Tabellen, umkehrbar. Der Schlüssel ist
// durchgehend die MBID, sodass der Graph später verlustfrei an die
// Recording-MBIDs der Bibliothek joinbar ist.
//
// Die GRDB-Konformität sitzt hier per Erweiterung — das Domänenmodell
// (`RelationGraph.swift`) bleibt SQL-frei. Kanten sind gerichtet; Knoten werden
// beim Schreiben *gemergt*, damit ein reicher Release-Lookup (mit Label) einen
// zuvor nur aus einer Kante angelegten Stummel ergänzt, statt ihn zu leeren.
//

import Foundation
import GRDB

// MARK: - GRDB-Konformität (additiv, hält das Domänenmodell rein)

extension GraphNode: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "mb_entities" }
}

extension GraphEdge: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "mb_relations" }
}

// MARK: - Store

public final class RelationStore {
    private let dbQueue: DatabaseQueue

    /// - Parameter path: Pfad der SQLite-Datei. Wird angelegt, falls nicht vorhanden.
    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_relation_graph") { db in
            // Knoten: eine Zeile je MBID, angereichert über die Zeit.
            try db.create(table: GraphNode.databaseTableName, ifNotExists: true) { t in
                t.column("mbid", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("title", .text)
                t.column("artist", .text)
                t.column("year", .integer)
                t.column("label", .text)
                t.column("primary_type", .text)
            }
            // Kanten: gerichtet, eine je (Quelle, Ziel, Beziehung).
            try db.create(table: GraphEdge.databaseTableName, ifNotExists: true) { t in
                t.column("source_mbid", .text).notNull()
                t.column("target_mbid", .text).notNull()
                t.column("relation", .text).notNull()
                t.column("target_kind", .text).notNull()
                t.primaryKey(["source_mbid", "target_mbid", "relation"])
            }
        }
        return migrator
    }

    // MARK: Schreiben

    /// Speichert einen Knoten *mergend*: gesetzte Fakten des neuen Knotens
    /// gewinnen, ein bestehender Wert geht aber nie durch ein `nil` verloren.
    public func saveEntity(_ node: GraphNode) throws {
        try dbQueue.write { db in
            try Self.upsert(node, in: db)
        }
    }

    /// Speichert eine Kante; eine bestehende Kante gleicher (Quelle, Ziel,
    /// Beziehung) wird ersetzt.
    public func saveEdge(_ edge: GraphEdge) throws {
        try dbQueue.write { db in
            try edge.insert(db, onConflict: .replace)
        }
    }

    /// Speichert einen ganzen Fragment-Ausschnitt (Knoten gemergt, Kanten ersetzt)
    /// in einer Transaktion.
    public func save(_ fragment: RelationGraphBuilder.Fragment) throws {
        try dbQueue.write { db in
            for node in fragment.nodes { try Self.upsert(node, in: db) }
            for edge in fragment.edges { try edge.insert(db, onConflict: .replace) }
        }
    }

    private static func upsert(_ node: GraphNode, in db: Database) throws {
        if let existing = try GraphNode.fetchOne(db, key: node.mbid) {
            try node.merged(with: existing).insert(db, onConflict: .replace)
        } else {
            try node.insert(db)
        }
    }

    // MARK: Lesen

    public func entityCount() throws -> Int {
        try dbQueue.read { db in try GraphNode.fetchCount(db) }
    }

    public func edgeCount() throws -> Int {
        try dbQueue.read { db in try GraphEdge.fetchCount(db) }
    }

    public func entity(mbid: String) throws -> GraphNode? {
        try dbQueue.read { db in try GraphNode.fetchOne(db, key: mbid) }
    }

    /// Knoten, deren Titel den Text (case-insensitiv) enthält — für die
    /// Ankersuche im CLI („begehe den Faden ab diesem Titel").
    public func entities(titleContains text: String) throws -> [GraphNode] {
        try dbQueue.read { db in
            try GraphNode
                .filter(sql: "title LIKE ? COLLATE NOCASE", arguments: ["%\(text)%"])
                .order(Column("year"), Column("title"))
                .fetchAll(db)
        }
    }

    /// Lädt den gesamten Graphen in den Speicher — bei einer persönlichen Scheibe
    /// problemlos, und die Traversierung bleibt reine, SQL-freie Logik.
    public func loadGraph() throws -> RelationGraph {
        try dbQueue.read { db in
            let nodes = try GraphNode.order(Column("mbid")).fetchAll(db)
            let edges = try GraphEdge
                .order(Column("source_mbid"), Column("relation"), Column("target_mbid"))
                .fetchAll(db)
            return RelationGraph(nodes: nodes, edges: edges)
        }
    }
}
