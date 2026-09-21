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

    @Published private(set) var items: [Item] = []
    @Published private(set) var scanning = false
    @Published private(set) var note: String?

    /// Kept across refreshes so re-scanning a folder does not silently tick
    /// a track the user had unticked.
    private var excluded: Set<String> = []
    private var token = 0

    var includedPaths: Set<String> {
        Set(items.filter(\.included).map(\.path))
    }

    /// The ones that will actually be processed: the included tracks, in
    /// order, up to the limit.
    func willProcess(limit: Int) -> Set<String> {
        Set(items.filter(\.included).prefix(limit).map(\.path))
    }

    func setIncluded(_ included: Bool, for path: String) {
        guard let index = items.firstIndex(where: { $0.path == path }) else { return }
        items[index].included = included
        if included { excluded.remove(path) } else { excluded.insert(path) }
    }

    func setAll(_ included: Bool) {
        for index in items.indices { items[index].included = included }
        excluded = included ? [] : Set(items.map(\.path))
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
            items = []; note = nil; scanning = false; excluded = []
            return
        }
        scanning = true
        defer { if mine == token { scanning = false } }

        let found = await Task.detached(priority: .userInitiated) {
            var audio: [URL] = []
            var skipped: [String: Int] = [:]
            var errors: [String] = []
            for folder in folders {
                let result = FileSurvey.survey(folder)
                audio += result.audio
                for (suffix, count) in result.skipped {
                    skipped[suffix, default: 0] += count
                }
                errors += result.errors
            }
            return (audio, skipped, errors)
        }.value
        guard mine == token else { return }   // a later refresh overtook this one

        let (audio, skipped, errors) = found
        var rows = audio.map { url in
            Item(path: url.path,
                 name: url.deletingPathExtension().lastPathComponent,
                 folder: url.deletingLastPathComponent().lastPathComponent,
                 included: !excluded.contains(url.path))
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

        items = rows
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
