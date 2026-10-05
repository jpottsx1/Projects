import Foundation
import LoudnessKit

/// What is about to be processed, visible before pressing anything.
///
/// Without this the app asked you to choose folders and a limit and then
/// told you afterwards what it had touched. The selection rule is not
/// obvious either -- it is thinnest low end first, not alphabetical, not
/// folder order -- so a queue that shows the order is the only way to see
/// what "10 tracks" actually means for a folder of three hundred.
@MainActor
final class Queue: ObservableObject {

    struct Item: Identifiable, Equatable {
        let path: String
        var name: String
        var folder: String
        /// Nil until the track has been measured. Both come from the
        /// library, so a folder scanned earlier arrives already filled in.
        var lowEndDB: Double?
        var lufsI: Double?
        var included: Bool = true

        var id: String { path }
        var measured: Bool { lowEndDB != nil }
    }

    /// What the list shows: the pool, limited to `scope` when a host has said
    /// which tracks it means. Everything that changes a row changes the pool
    /// and calls `publish()`.
    @Published private(set) var items: [Item] = []
    /// Everything the scan found plus the files a host sent.
    private var pool: [Item] = []
    /// Nil shows everything. A host that says "these tracks" sets it, so the
    /// list is those tracks and not the whole folder with some ticked.
    private var scope: Set<String>?

    private func publish() {
        if let scope { items = pool.filter { scope.contains($0.path) } } else { items = pool }
    }

    /// Show only these tracks (the ones a host sent), ticked. Tracks the
    /// queue does not hold yet are added first.
    func show(only urls: [URL]) {
        adopt(urls)
        let paths = Set(urls.map(\.path))
        scope = paths
        for index in pool.indices where paths.contains(pool[index].path) {
            pool[index].included = true
        }
        excluded.subtract(paths)
        publish()
    }

    /// Back to showing everything the scan found.
    func showEverything() {
        scope = nil
        publish()
    }

    /// Empties the list entirely: the scan, the files a host sent, the
    /// remembered unticks and the scope. (A refresh with no folders keeps
    /// the sent files on purpose, so this is the one that really clears.)
    func clearAll() {
        token += 1
        pool = []; added = []; excluded = []; scope = nil
        items = []; note = nil; scanning = false
    }
    @Published private(set) var scanning = false
    @Published private(set) var note: String?

    /// Kept across refreshes so re-scanning a folder does not silently tick
    /// a track the user had unticked.
    private var excluded: Set<String> = []
    private var token = 0
    /// Files a host sent that no scanned folder contains (a track from a
    /// crate, a single file). Kept apart from the scan so a refresh, which
    /// rebuilds `items` from the folders, does not drop them.
    private var added: [Item] = []

    /// Adds files the host wants worked on and ticks them. A path the queue
    /// already holds is just ticked; one it does not hold used to be ignored
    /// silently, which looked like "Send to Loudness Lab does nothing".
    func adopt(_ urls: [URL]) {
        var known = Set(pool.map(\.path))
        for url in urls {
            let path = url.path
            if known.contains(path) {
                if let i = pool.firstIndex(where: { $0.path == path }) { pool[i].included = true }
                excluded.remove(path)
                continue
            }
            known.insert(path)
            let item = Item(path: path,
                            name: url.deletingPathExtension().lastPathComponent,
                            folder: "Sent from Disco Tags")
            added.removeAll { $0.path == path }
            added.append(item)
            excluded.remove(path)
            pool.append(item)
        }
        publish()
    }

    var includedPaths: Set<String> {
        Set(items.filter(\.included).map(\.path))
    }

    /// The ones that will actually be processed: the included tracks, in
    /// order, up to the limit.
    func willProcess(limit: Int) -> Set<String> {
        Set(items.filter(\.included).prefix(limit).map(\.path))
    }

    func setIncluded(_ included: Bool, for path: String) {
        guard let index = pool.firstIndex(where: { $0.path == path }) else { return }
        pool[index].included = included
        if included { excluded.remove(path) } else { excluded.insert(path) }
        publish()
    }

    func setAll(_ included: Bool) {
        // The rows on show: a tick or untick-all does not reach the ones a
        // host has left out of the list.
        let shown = Set(items.map(\.path))
        for index in pool.indices where shown.contains(pool[index].path) {
            pool[index].included = included
        }
        if included { excluded.subtract(shown) } else { excluded.formUnion(shown) }
        publish()
    }

    /// Survey the folders, then fill in whatever the library already knows.
    ///
    /// Two stages on purpose: walking the disk is quick and gives you a list
    /// to look at straight away, while the measurements may not exist yet.
    /// A track with no numbers is not an error, it just has not been
    /// measured -- pressing Process measures it.
    func refresh(folders: [URL], databaseURL: URL) async {
        token += 1
        let mine = token
        guard !folders.isEmpty else {
            // Cleared, so the remembered ticks go too. Keeping them would
            // mean a track unticked weeks ago silently staying out of a run
            // its folder was added back for.
            pool = added; note = nil; scanning = false; excluded = []
            publish()
            return
        }
        scanning = true
        defer { if mine == token { scanning = false } }

        let found = await Task.detached(priority: .userInitiated) {
            // Tagged with the root folder actually added, not the file's
            // own immediate parent -- a multi-disc release added as one
            // folder is one release. Without this, "Now Yearbook 99
            // (2026)" split into CD1..CD4 subfolders would list as four
            // unrelated folders instead of the one thing that was added.
            var audio: [(url: URL, root: String)] = []
            var skipped: [String: Int] = [:]
            var errors: [String] = []
            for folder in folders {
                let result = FileSurvey.survey(folder)
                let root = folder.lastPathComponent
                audio += result.audio.map { (url: $0, root: root) }
                for (suffix, count) in result.skipped {
                    skipped[suffix, default: 0] += count
                }
                errors += result.errors
            }
            return (audio, skipped, errors)
        }.value
        guard mine == token else { return }   // a later refresh overtook this one

        let (audio, skipped, errors) = found
        var rows = audio.map { entry in
            Item(path: entry.url.path,
                 name: entry.url.deletingPathExtension().lastPathComponent,
                 folder: entry.root,
                 included: !excluded.contains(entry.url.path))
        }

        // Anything already measured, so the order and the numbers are real
        // before a single file is decoded. A missing database is the normal
        // state on a first run, not a failure worth reporting.
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let known = await Task.detached(priority: .userInitiated) {
                () -> ([String: Double], [String: (String, Double?)]) in
                guard let library = try? Library(at: databaseURL) else { return ([:], [:]) }
                let shape = (try? library.lowEndShape(under: folders)) ?? [:]
                var named: [String: (String, Double?)] = [:]
                for row in (try? library.tracks(under: folders)) ?? [] {
                    named[row.path] = (row.name, row.lufsI)
                }
                return (shape, named)
            }.value
            guard mine == token else { return }

            let (shape, named) = known
            for index in rows.indices {
                if let (name, lufs) = named[rows[index].path] {
                    rows[index].name = name
                    rows[index].lufsI = lufs
                }
                rows[index].lowEndDB = shape[rows[index].path]
            }
        }

        // The processing order, restated: thinnest low end first, because
        // those are the tracks the sub stage is for. Unmeasured tracks
        // cannot be placed yet, so they follow, by name.
        rows.sort { left, right in
            switch (left.lowEndDB, right.lowEndDB) {
            case let (l?, r?): return l == r ? left.name < right.name : l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return left.name < right.name
            }
        }

        let scanned = Set(rows.map(\.path))
        pool = rows + added.filter { !scanned.contains($0.path) }
        publish()
        note = Queue.note(found: rows.count, skipped: skipped, errors: errors)
    }

    /// What was passed over, said out loud. A library that comes back
    /// smaller than expected is nearly always an extension not on the list.
    private static func note(found: Int, skipped: [String: Int],
                             errors: [String]) -> String? {
        var parts: [String] = []
        if found == 0 { parts.append("No audio found.") }
        if !skipped.isEmpty {
            let listed = skipped.sorted { $0.value > $1.value }.prefix(4)
                .map { ".\($0.key) x\($0.value)" }.joined(separator: ", ")
            parts.append("Passed over \(listed).")
        }
        if let first = errors.first {
            parts.append(errors.count > 1
                         ? "\(first) (and \(errors.count - 1) more)" : first)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
