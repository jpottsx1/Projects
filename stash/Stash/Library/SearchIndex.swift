import Foundation
import SQLite3

/// Full-text search over every item, using SQLite's FTS5 (built into the
/// system SQLite on macOS and iOS). Kept beside the library rather than in
/// it: it holds nothing that can't be rebuilt from the items, and it is
/// rebuilt at every launch, so it can never drift out of step for long.
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
        guard created else {
            sqlite3_close(db)
            db = nil  // deinit still runs; closing twice would be a crash
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func replaceAll(with entries: [Entry]) {
        execute("BEGIN")
        execute("DELETE FROM entries")
        for entry in entries { insert(entry) }
        execute("COMMIT")
    }

    func update(_ entry: Entry) {
        execute("BEGIN")
        remove(entry.id)
        insert(entry)
        execute("COMMIT")
    }

    func remove(_ id: UUID) {
        run("DELETE FROM entries WHERE id = ?", [id.uuidString])
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

    private func insert(_ entry: Entry) {
        run("INSERT INTO entries (id, title, body, tags, extra) VALUES (?, ?, ?, ?, ?)",
            [entry.id.uuidString, entry.title, entry.body, entry.tags, entry.extra])
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
