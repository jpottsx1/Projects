import Foundation

/// The scan database: one row per track, one per 1/3-octave band.
///
/// The SQL is character-for-character the Python's, and the schema version
/// is the same number, so a database written by either opens in the other.
/// That is not tidiness -- re-analysing a real library costs hours, and a
/// person who has already scanned six hundred tracks from the command line
/// should not have to do it again to open the app.
public final class Library {

    public static let schemaVersion = 4
    public static let toolVersion = "0.1.0"

    public static let schema = """
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS tracks (
        id              INTEGER PRIMARY KEY,
        path            TEXT UNIQUE NOT NULL,
        size_bytes      INTEGER,
        mtime_ns        INTEGER,
        analyzed_at     TEXT,
        tool_version    TEXT,
        status          TEXT NOT NULL,
        error           TEXT,
        codec           TEXT,
        source_rate     INTEGER,
        source_channels INTEGER,
        bitrate_kbps    REAL,
        duration_s      REAL,
        artist          TEXT,
        title           TEXT,
        album           TEXT,
        genre           TEXT,
        year            INTEGER,
        year_is_original INTEGER,
        bpm             REAL,
        musical_key     TEXT
    );

    CREATE TABLE IF NOT EXISTS loudness (
        track_id         INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
        lufs_i           REAL,
        lra              REAL,
        s_max            REAL,
        s_p95            REAL,
        s_p90            REAL,
        s_p50            REAL,
        s_p10            REAL,
        true_peak_dbtp   REAL,
        sample_peak_dbfs REAL,
        crest_db         REAL,
        clipped_samples  INTEGER,
        clip_runs        INTEGER
    );

    CREATE TABLE IF NOT EXISTS bands (
        track_id    INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        band_hz     REAL NOT NULL,
        ltas_db     REAL,
        shape_db    REAL,
        p10_db      REAL,
        p90_db      REAL,
        side_mid_db REAL,
        PRIMARY KEY (track_id, band_hz)
    );

    CREATE TABLE IF NOT EXISTS gain_log (
        id          INTEGER PRIMARY KEY,
        path        TEXT NOT NULL,
        output_path TEXT NOT NULL,
        steps       INTEGER NOT NULL,
        applied_db  REAL NOT NULL,
        in_place    INTEGER NOT NULL,
        applied_at  TEXT NOT NULL,
        undone_at   TEXT,
        crossed_bits TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_tracks_year ON tracks(year);
    CREATE INDEX IF NOT EXISTS idx_tracks_status ON tracks(status);
    CREATE INDEX IF NOT EXISTS idx_bands_hz ON bands(band_hz);
    """

    let db: SQLite
    public let url: URL

    public init(at url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLite(path: url.path)
        try db.execute("PRAGMA foreign_keys = ON;")
        try db.execute("PRAGMA journal_mode = WAL;")
        try db.execute(Library.schema)

        let stored = try db.run("SELECT value FROM meta WHERE key = 'schema_version'")
        if let text = stored.first?["value"] as? String, let version = Int(text) {
            try migrate(from: version)
        } else {
            try db.run("INSERT INTO meta (key, value) VALUES ('schema_version', ?)",
                       [.text(String(Library.schemaVersion))])
        }
    }

    /// Bring an older database forward rather than making someone re-run it.
    /// Columns added this way stay NULL on existing rows, which reports have
    /// to read as "unknown" rather than as a value.
    func migrate(from version: Int) throws {
        guard version <= Library.schemaVersion else {
            throw SQLite.Failure(
                "database is schema v\(version), newer than this build's "
                + "v\(Library.schemaVersion). Update the app, or scan into a new file.")
        }
        if version < 4 {
            let columns = try db.run("PRAGMA table_info(gain_log)")
                .compactMap { $0["name"] as? String }
            if !columns.isEmpty, !columns.contains("crossed_bits") {
                try db.run("ALTER TABLE gain_log ADD COLUMN crossed_bits TEXT")
            }
        }
        if version < 2 {
            let columns = try db.run("PRAGMA table_info(tracks)")
                .compactMap { $0["name"] as? String }
            if !columns.contains("year_is_original") {
                try db.run("ALTER TABLE tracks ADD COLUMN year_is_original INTEGER")
            }
        }
        try db.run("UPDATE meta SET value = ? WHERE key = 'schema_version'",
                   [.text(String(Library.schemaVersion))])
    }

    // MARK: - Results

    public struct Analysis: Sendable {
        public var url: URL
        public var sizeBytes: Int
        public var mtimeNanoseconds: Int
        public var status: String
        public var error: String?
        public var tags: Tags
        public var codec: String?
        public var loudness: BS1770.Result?
        public var bands: [Spectrum.Band]

        public init(url: URL, sizeBytes: Int, mtimeNanoseconds: Int, status: String,
                    error: String? = nil, tags: Tags = Tags(), codec: String? = nil,
                    loudness: BS1770.Result? = nil, bands: [Spectrum.Band] = []) {
            self.url = url; self.sizeBytes = sizeBytes
            self.mtimeNanoseconds = mtimeNanoseconds; self.status = status
            self.error = error; self.tags = tags; self.codec = codec
            self.loudness = loudness; self.bands = bands
        }
    }

    /// True unless there is already a current, successful result for this
    /// file. Size and modification time together are what make re-running a
    /// scan over a large folder cheap.
    public func needsAnalysis(_ url: URL, size: Int, mtimeNanoseconds: Int) throws -> Bool {
        let rows = try db.run(
            "SELECT size_bytes, mtime_ns, status, tool_version FROM tracks WHERE path = ?",
            [.text(url.path)])
        guard let row = rows.first, row["status"] as? String == "ok" else { return true }
        return row["size_bytes"] as? Int != size
            || row["mtime_ns"] as? Int != mtimeNanoseconds
            || row["tool_version"] as? String != Library.toolVersion
    }

    static let trackFields = ["codec", "source_rate", "source_channels",
                              "bitrate_kbps", "duration_s", "artist", "title",
                              "album", "genre", "year", "year_is_original",
                              "bpm", "musical_key"]
    static let loudnessFields = ["lufs_i", "lra", "s_max", "s_p95", "s_p90",
                                 "s_p50", "s_p10", "true_peak_dbtp",
                                 "sample_peak_dbfs", "crest_db",
                                 "clipped_samples", "clip_runs"]
    static let bandFields = ["band_hz", "ltas_db", "shape_db", "p10_db",
                             "p90_db", "side_mid_db"]

    /// Write one track's results, replacing any previous attempt.
    public func store(_ result: Analysis) throws {
        let formatter = ISO8601DateFormatter()
        var columns = ["path", "size_bytes", "mtime_ns", "analyzed_at",
                       "tool_version", "status", "error"]
        var values: [SQLite.Value] = [
            .text(result.url.path), .int(Int64(result.sizeBytes)),
            .int(Int64(result.mtimeNanoseconds)),
            .text(formatter.string(from: Date())), .text(Library.toolVersion),
            .text(result.status), SQLite.Value(result.error),
        ]
        let tags = result.tags
        columns += Library.trackFields
        values += [
            SQLite.Value(result.codec), SQLite.Value(tags.sourceRate),
            SQLite.Value(tags.sourceChannels), SQLite.Value(nil as Double?),
            SQLite.Value(tags.durationSeconds), SQLite.Value(tags.artist),
            SQLite.Value(tags.title), SQLite.Value(tags.album),
            SQLite.Value(tags.genre), SQLite.Value(tags.year),
            SQLite.Value(tags.yearIsOriginal), SQLite.Value(tags.bpm),
            SQLite.Value(tags.musicalKey),
        ]

        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let updates = columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        try db.run("INSERT INTO tracks (\(columns.joined(separator: ", "))) "
                   + "VALUES (\(placeholders)) "
                   + "ON CONFLICT(path) DO UPDATE SET \(updates)", values)

        guard let trackID = try db.run("SELECT id FROM tracks WHERE path = ?",
                                       [.text(result.url.path)]).first?["id"] as? Int
        else { return }

        try db.run("DELETE FROM loudness WHERE track_id = ?", [.int(Int64(trackID))])
        try db.run("DELETE FROM bands WHERE track_id = ?", [.int(Int64(trackID))])

        if let m = result.loudness {
            let names = ["track_id"] + Library.loudnessFields
            try db.run("INSERT INTO loudness (\(names.joined(separator: ", "))) "
                       + "VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))",
                       [.int(Int64(trackID)), SQLite.Value(m.lufsI), SQLite.Value(m.lra),
                        SQLite.Value(m.sMax), SQLite.Value(m.sP95), SQLite.Value(m.sP90),
                        SQLite.Value(m.sP50), SQLite.Value(m.sP10),
                        SQLite.Value(m.truePeakDBTP), SQLite.Value(m.samplePeakDBFS),
                        SQLite.Value(m.crestDB), SQLite.Value(m.clippedSamples),
                        SQLite.Value(m.clipRuns)])
        }
        for band in result.bands {
            let names = ["track_id"] + Library.bandFields
            try db.run("INSERT INTO bands (\(names.joined(separator: ", "))) "
                       + "VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))",
                       [.int(Int64(trackID)), SQLite.Value(band.bandHz),
                        SQLite.Value(band.ltasDB), SQLite.Value(band.shapeDB),
                        SQLite.Value(band.p10DB), SQLite.Value(band.p90DB),
                        SQLite.Value(band.sideMidDB)])
        }
    }

    // MARK: - Reading

    public struct TrackRow: Identifiable, Sendable {
        public let id: Int
        public let path: String
        public let artist: String?, title: String?, album: String?
        public let year: Int?
        public let lufsI: Double?, sP95: Double?, lra: Double?
        public let truePeakDBTP: Double?, crestDB: Double?
        public let clipRuns: Int?

        public var name: String {
            [artist, title].compactMap { $0 }.joined(separator: " - ")
                .isEmpty ? (path as NSString).lastPathComponent
                         : [artist, title].compactMap { $0 }.joined(separator: " - ")
        }
    }

    public func tracks(under roots: [URL] = []) throws -> [TrackRow] {
        var sql = """
        SELECT t.id, t.path, t.artist, t.title, t.album, t.year,
               l.lufs_i, l.s_p95, l.lra, l.true_peak_dbtp, l.crest_db, l.clip_runs
        FROM tracks t LEFT JOIN loudness l ON l.track_id = t.id
        WHERE t.status = 'ok'
        """
        var values: [SQLite.Value] = []
        if !roots.isEmpty {
            // Scoped to the folders named. The database is shared -- a
            // reference corpus has to live in it too -- so without this a
            // selection ranges over every track it holds.
            let clauses = roots.map { _ in "(t.path = ? OR t.path LIKE ?)" }
            sql += " AND (" + clauses.joined(separator: " OR ") + ")"
            for root in roots {
                let base = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
                values.append(.text(base))
                values.append(.text(base + "/%"))
            }
        }
        sql += " ORDER BY t.path"
        return try db.run(sql, values).compactMap { row in
            guard let id = row["id"] as? Int, let path = row["path"] as? String
            else { return nil }
            return TrackRow(id: id, path: path,
                            artist: row["artist"] as? String,
                            title: row["title"] as? String,
                            album: row["album"] as? String,
                            year: row["year"] as? Int,
                            lufsI: row["lufs_i"] as? Double,
                            sP95: row["s_p95"] as? Double,
                            lra: row["lra"] as? Double,
                            truePeakDBTP: row["true_peak_dbtp"] as? Double,
                            crestDB: row["crest_db"] as? Double,
                            clipRuns: row["clip_runs"] as? Int)
        }
    }

    /// Mean `shape_db` across the low bands, per track -- what the sub stage
    /// selects on.
    public func lowEndShape(under roots: [URL] = []) throws -> [String: Double] {
        let bands = Spectrum.bandCentres.filter { $0 <= Spectrum.lowBandMaxHz }
        let list = bands.map(String.init).joined(separator: ", ")
        var sql = """
        SELECT t.path, AVG(b.shape_db) AS low FROM tracks t
        JOIN bands b ON b.track_id = t.id
        WHERE t.status = 'ok' AND b.band_hz IN (\(list)) AND b.shape_db IS NOT NULL
        """
        var values: [SQLite.Value] = []
        if !roots.isEmpty {
            sql += " AND (" + roots.map { _ in "(t.path = ? OR t.path LIKE ?)" }
                .joined(separator: " OR ") + ")"
            for root in roots {
                let base = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
                values.append(.text(base)); values.append(.text(base + "/%"))
            }
        }
        sql += " GROUP BY t.id"
        var out: [String: Double] = [:]
        for row in try db.run(sql, values) {
            if let path = row["path"] as? String, let low = row["low"] as? Double {
                out[path] = low
            }
        }
        return out
    }

    public func recordGain(path: String, outputPath: String, steps: Int,
                           appliedDB: Double, inPlace: Bool, crossed: [Int]) throws {
        try db.run("""
            INSERT INTO gain_log (path, output_path, steps, applied_db, in_place,
                                  applied_at, crossed_bits)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(path), .text(outputPath), .int(Int64(steps)), .double(appliedDB),
             .int(inPlace ? 1 : 0),
             .text(ISO8601DateFormatter().string(from: Date())),
             .text(crossed.map(String.init).joined(separator: ","))])
    }
}
