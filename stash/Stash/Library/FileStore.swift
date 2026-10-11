import CryptoKit
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

    func exists(_ storedPath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: storedPath).path)
    }

    /// Writes out a file that arrived from another device.
    func write(_ data: Data, to storedPath: String) throws {
        let destination = url(for: storedPath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    /// The file's SHA-256 as hex, read a piece at a time so a large file
    /// isn't loaded whole. Slow for big files: call it off the main thread.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 4 * 1024 * 1024) else { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Removes the item's whole folder.
    func remove(_ storedPath: String) {
        guard let folder = storedPath.split(separator: "/").first else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(String(folder), isDirectory: true))
    }

    /// Removes the folders of items that no longer exist -- documents
    /// deleted on another device.
    func removeFolders(notBelongingTo ids: Set<UUID>) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
