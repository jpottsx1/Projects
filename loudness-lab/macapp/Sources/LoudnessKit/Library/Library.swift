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

        /// Artist and title where the file has them, its own name where it
        /// does not -- an untagged track should still be identifiable.
        public var name: String {
            let tagged = [artist, title].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: " - ")
            return tagged.isEmpty ? (path as NSString).lastPathComponent : tagged
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
    /// A comma-separated list for an SQL `IN` clause.
    ///
    /// Written the long way deliberately. `values.map(String.init).joined(...)`
    /// reads better and does not compile: with the element type left to be
    /// inferred, Swift cannot choose between `Sequence.joined(separator:)`
    /// returning a sequence and the one returning a String, and gives up.
    /// Naming the intermediate type settles it.
    static func sqlList(_ values: [Double]) -> String {
        let texts: [String] = values.map { String($0) }
        return texts.joined(separator: ", ")
    }

    public func lowEndShape(under roots: [URL] = []) throws -> [String: Double] {
        let bands = Spectrum.bandCentres.filter { $0 <= Spectrum.lowBandMaxHz }
        let list = Library.sqlList(bands)
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

    /// The bands the sub stage reasons about: 31.5 to 63 Hz. Above 80 Hz
    /// every era in this project's corpora agrees within about a decibel, so
    /// there is nothing there to correct.
    public static let lowShapeBands = Spectrum.bandCentres.filter { (31.0...63.0).contains($0) }

    /// Median low-band shape per folder -- the curve a track is measured
    /// against when the sub is sized per track rather than set by hand.
    public func referenceCurves() throws -> [String: [Double: Double]] {
        let list = Library.sqlList(Library.lowShapeBands)
        let rows = try db.run("""
            SELECT t.path, b.band_hz, b.shape_db FROM tracks t
            JOIN bands b ON b.track_id = t.id
            WHERE t.status = 'ok' AND b.band_hz IN (\(list)) AND b.shape_db IS NOT NULL
            """)
        var gathered: [String: [Double: [Double]]] = [:]
        for row in rows {
            guard let path = row["path"] as? String,
                  let band = row["band_hz"] as? Double,
                  let shape = row["shape_db"] as? Double else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            let name = (folder as NSString).lastPathComponent
            gathered[name, default: [:]][band, default: []].append(shape)
        }
        return gathered.mapValues { bands in
            bands.compactMapValues { BS1770.percentile($0, 50) }
        }
    }

    /// An exact folder name, else a unique case-insensitive substring of one.
    /// Ambiguity returns nothing rather than a guess: sizing every track in a
    /// library against the wrong corpus is not a mistake worth making quietly.
    public static func resolveReference(_ curves: [String: [Double: Double]],
                                        _ wanted: String) -> String? {
        if curves[wanted] != nil { return wanted }
        let matches = curves.keys.filter { $0.lowercased().contains(wanted.lowercased()) }
        return matches.count == 1 ? matches.first : nil
    }

    /// Mean shortfall of one track against a reference curve, in dB, and the
    /// reason when there is nothing to do.
    public func shortfall(of path: String, against curve: [Double: Double],
                          cap: Double) throws -> (amount: Double, reason: String?) {
        let list = Library.sqlList(Library.lowShapeBands)
        let rows = try db.run("""
            SELECT b.band_hz, b.shape_db FROM bands b
            JOIN tracks t ON t.id = b.track_id
            WHERE t.path = ? AND b.band_hz IN (\(list))
            """, [.text(path)])
        var deficits: [Double] = []
        for row in rows {
            guard let band = row["band_hz"] as? Double,
                  let target = curve[band],
                  let shape = row["shape_db"] as? Double else { continue }
            deficits.append(target - shape)
        }
        guard !deficits.isEmpty else { return (0, "no band data") }
        let mean = deficits.reduce(0, +) / Double(deficits.count)
        // Half a decibel is below what anyone can hear on a dancefloor and
        // well inside the spread between pressings of the same record.
        guard mean > 0.5 else {
            return (0, String(format: "already within %.1f dB of the reference", mean))
        }
        return (min(mean, cap), nil)
    }

    public func recordGain(path: String, outputPath: String, steps: Int,
                           appliedDB: Double, inPlace: Bool, crossed: [Int]) throws {
        let bits: [String] = crossed.map { String($0) }
        let crossedBits = bits.joined(separator: ",")
        try db.run("""
            INSERT INTO gain_log (path, output_path, steps, applied_db, in_place,
                                  applied_at, crossed_bits)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(path), .text(outputPath), .int(Int64(steps)), .double(appliedDB),
             .int(inPlace ? 1 : 0),
             .text(ISO8601DateFormatter().string(from: Date())),
             .text(crossedBits)])
    }
}
