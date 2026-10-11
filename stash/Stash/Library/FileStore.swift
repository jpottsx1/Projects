import Foundation

/// Imported documents are copied into the app's own folder, one subfolder
/// per item, keeping their original names. The library database stores only
/// where each copy is, which keeps the database small.
struct FileStore {
    let root: URL

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Copies `source` in and returns the path to store on the item.
    func importFile(at source: URL, for id: UUID) throws -> String {
        // Files from the picker, or dropped from elsewhere, can only be read
        // inside this bracket.
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return "\(id.uuidString)/\(source.lastPathComponent)"
    }

    func url(for storedPath: String) -> URL {
        root.appendingPathComponent(storedPath)
    }

    /// Removes the item's whole folder.
    func remove(_ storedPath: String) {
        guard let folder = storedPath.split(separator: "/").first else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(String(folder), isDirectory: true))
    }
}
