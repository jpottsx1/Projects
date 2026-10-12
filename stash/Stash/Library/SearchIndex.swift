import Foundation
import SQLite3

/// Full-text search over every item, using SQLite's FTS5 (built into the
/// system SQLite on macOS and iOS). Kept beside the library rather than in
/// it: it holds nothing that can't be rebuilt from the items. At launch and
/// after changes from iCloud it's brought into step with them (`sync`):
/// each entry keeps a signature of what it was made from, so only items
/// that have changed are indexed again.
///
/// Ranked with BM25, weighting a match in the title most, then tags, then
/// the text itself, then extracted text (page and PDF contents) least.
final class SearchIndex {
    struct Entry {
        var id: UUID
        var title: String
        var body: String
        var tags: String
        var extra: String
    }

    private var db: OpaquePointer?

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil  // deinit still runs; closing twice would be a crash
            return nil
        }
        // Nothing here is irreplaceable, so skip waiting for the disk on
        // every keystroke's update.
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA synchronous = OFF")
        // Porter stemming so "running" finds "run"; diacritics ignored so
        // "cafe" finds "café".
        let created = execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entries USING fts5(
                id UNINDEXED, title, body, tags, extra,
                tokenize = 'porter unicode61 remove_diacritics 2')
            """)
        // Each entry's signature, and its row in `entries` (whose id column
        // isn't indexed, so finding a row by id means reading every one).
        let stamped = execute(
            "CREATE TABLE IF NOT EXISTS stamps (id TEXT PRIMARY KEY, signature TEXT NOT NULL, row INTEGER NOT NULL)")
        guard created, stamped else {
            sqlite3_close(db)
            db = nil  // deinit still runs; closing twice would be a crash
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// Brings the index into step with the items: `wanted` is each item's
    /// signature, and `entry` makes the entry for one that's new or has
    /// changed. Gives what was indexed again, and what was taken out.
    @discardableResult
    func sync(_ wanted: [UUID: String], entry: (UUID) -> Entry?) -> (changed: [UUID], removed: [UUID]) {
        let have = signatures()
        execute("BEGIN")
        defer { execute("COMMIT") }
        // Nothing signed (a new index, or one from before signatures): start again.
        if have.isEmpty {
            execute("DELETE FROM entries")
            execute("DELETE FROM stamps")
            for (id, signature) in wanted {
                guard let made = entry(id) else { continue }
                stamp(id, signature, row: insert(made))
            }
            return (Array(wanted.keys), [])
        }
        let removed = have.keys.filter { wanted[$0] == nil }
        for id in removed { removeRow(of: id) }
        var changed: [UUID] = []
        for (id, signature) in wanted where have[id] != signature {
            guard let made = entry(id) else { continue }
            removeRow(of: id)
            stamp(id, signature, row: insert(made))
            changed.append(id)
        }
        return (changed, Array(removed))
    }

    func update(_ entry: Entry, signature: String) {
        execute("BEGIN")
        removeRow(of: entry.id)
        stamp(entry.id, signature, row: insert(entry))
        execute("COMMIT")
    }

    func remove(_ id: UUID) {
        removeRow(of: id)
    }

    /// Item ids matching an FTS5 expression (see `SearchQuery.ftsExpression`),
    /// best first. An expression SQLite can't read matches nothing.
    func search(_ expression: String, limit: Int = 1000) -> [UUID] {
        let sql = """
            SELECT id FROM entries WHERE entries MATCH ?
            ORDER BY bm25(entries, 0.0, 10.0, 1.0, 5.0, 0.5) LIMIT \(limit)
            """
        var ids: [UUID] = []
        run(sql, [expression]) { statement in
            if let text = sqlite3_column_text(statement, 0),
               let id = UUID(uuidString: String(cString: text)) {
                ids.append(id)
            }
        }
        return ids
    }

    /// How many items match an FTS5 expression; every item when nil.
    func count(matching expression: String? = nil) -> Int {
        var total = 0
        let read: (OpaquePointer) -> Void = { total = Int(sqlite3_column_int64($0, 0)) }
        if let expression {
            run("SELECT count(*) FROM entries WHERE entries MATCH ?", [expression], row: read)
        } else {
            run("SELECT count(*) FROM entries", [], row: read)
        }
        return total
    }

    // MARK: - SQLite

    private func signatures() -> [UUID: String] {
        var result: [UUID: String] = [:]
        run("SELECT id, signature FROM stamps", []) { statement in
            guard let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)),
                  let signature = sqlite3_column_text(statement, 1) else { return }
            result[id] = String(cString: signature)
        }
        return result
    }

    private func stamp(_ id: UUID, _ signature: String, row: Int64) {
        run("INSERT OR REPLACE INTO stamps (id, signature, row) VALUES (?, ?, ?)", [id.uuidString, signature, String(row)])
    }

    /// Takes an item's entry out: by its row when that's known, else by
    /// reading every entry for its id.
    private func removeRow(of id: UUID) {
        var row: Int64?
        run("SELECT row FROM stamps WHERE id = ?", [id.uuidString]) { row = sqlite3_column_int64($0, 0) }
        if let row {
            run("DELETE FROM entries WHERE rowid = CAST(? AS INTEGER)", [String(row)])
            run("DELETE FROM stamps WHERE id = ?", [id.uuidString])
        } else {
            run("DELETE FROM entries WHERE id = ?", [id.uuidString])
        }
    }

    /// Adds an entry and gives its row.
    @discardableResult
    private func insert(_ entry: Entry) -> Int64 {
        run("INSERT INTO entries (id, title, body, tags, extra) VALUES (?, ?, ?, ?, ?)",
            [entry.id.uuidString, entry.title, entry.body, entry.tags, entry.extra])
        return sqlite3_last_insert_rowid(db)
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Prepares `sql`, binds `values` in order, and calls `row` for each row.
    private func run(_ sql: String, _ values: [String], row: (OpaquePointer) -> Void = { _ in }) {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    /// SQLITE_TRANSIENT, which Swift can't import: tells SQLite to copy the
    /// string, since Swift's temporary C string is gone once the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
