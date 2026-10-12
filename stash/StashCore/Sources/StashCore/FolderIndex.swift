import Foundation

/// Keeping an indexed folder and the library in step: what's on disk now,
/// against what the library last saw there, as the changes to make.
///
/// A file that disappears from one place as one the same size and age
/// appears in another has been moved or renamed, not deleted and added:
/// its item keeps its tags, notes and highlights.
public enum FolderIndex {
    public struct File: Equatable {
        /// Inside the folder, with `/` between folders: "Taxes/2025.pdf".
        public var path: String
        public var size: Int
        public var modified: Date

        public init(path: String, size: Int, modified: Date) {
            self.path = path
            self.size = size
            self.modified = modified
        }
    }

    public struct Known: Equatable {
        public var id: UUID
        public var file: File

        public init(id: UUID, file: File) {
            self.id = id
            self.file = file
        }
    }

    public struct Changes: Equatable {
        public var added: [File] = []
        /// Same place, different contents.
        public var changed: [(id: UUID, file: File)] = []
        /// Same contents, different place.
        public var moved: [(id: UUID, file: File)] = []
        public var removed: [UUID] = []

        public var isEmpty: Bool { added.isEmpty && changed.isEmpty && moved.isEmpty && removed.isEmpty }

        public static func == (lhs: Changes, rhs: Changes) -> Bool {
            lhs.added == rhs.added && lhs.removed == rhs.removed
                && lhs.changed.map(\.id) == rhs.changed.map(\.id) && lhs.changed.map(\.file) == rhs.changed.map(\.file)
                && lhs.moved.map(\.id) == rhs.moved.map(\.id) && lhs.moved.map(\.file) == rhs.moved.map(\.file)
        }
    }

    public static func changes(onDisk: [File], known: [Known]) -> Changes {
        var changes = Changes()
        let knownByPath = Dictionary(known.map { ($0.file.path, $0) }, uniquingKeysWith: { first, _ in first })
        let diskPaths = Set(onDisk.map(\.path))
        var added: [File] = []
        for file in onDisk.sorted(by: { $0.path < $1.path }) {
            if let entry = knownByPath[file.path] {
                if entry.file.size != file.size || !sameSecond(entry.file.modified, file.modified) {
                    changes.changed.append((entry.id, file))
                }
            } else {
                added.append(file)
            }
        }
        var gone = known.filter { !diskPaths.contains($0.file.path) }.sorted { $0.file.path < $1.file.path }

        // Pair each vanished file with the one new file just like it.
        for file in added {
            let alike = gone.indices.filter { gone[$0].file.size == file.size && sameSecond(gone[$0].file.modified, file.modified) }
            let twins = added.filter { $0.size == file.size && sameSecond($0.modified, file.modified) }
            if alike.count == 1, twins.count == 1 {
                changes.moved.append((gone[alike[0]].id, file))
                gone.remove(at: alike[0])
            } else {
                changes.added.append(file)
            }
        }
        changes.removed = gone.map(\.id)
        return changes
    }

    /// File systems keep times to different precisions.
    private static func sameSecond(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 1
    }

    /// The folders a file is in, inside the indexed folder: "a/b/c.pdf" is in ["a", "b"].
    public static func folders(of path: String) -> [String] {
        Array(path.split(separator: "/").dropLast().map(String.init))
    }

    /// Whether a file should be left out: hidden files, and the clutter
    /// systems leave behind.
    public static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("~$") || ["Thumbs.db", "desktop.ini", "Icon\r"].contains(name)
    }
}
