import Foundation
import SwiftData
import StashCore

/// A folder kept in step with the library, one way, as Markdown files and
/// documents in a folder per category -- the readable half of an export,
/// `[[links]]` intact -- for Obsidian or any editor to read. Locked items
/// and saved web pages stay out. Settings are this device's, per library.
struct MirrorSettings: Codable, Equatable {
    var bookmark: Data?
    var folderName = ""
    var isOn = false
    var lastMirroredAt: Date?
    var lastError: String?
}

extension Library {
    private var mirrorKey: String { "mirror-" + supportFolder.lastPathComponent }
    private static let mirrorListName = ".stash-mirror.json"

    var mirrorSettings: MirrorSettings {
        get {
            UserDefaults.standard.data(forKey: mirrorKey)
                .flatMap { try? JSONDecoder().decode(MirrorSettings.self, from: $0) } ?? MirrorSettings()
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: mirrorKey)
        }
    }

    func chooseMirrorFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        var settings = mirrorSettings
        settings.bookmark = bookmark
        settings.folderName = url.lastPathComponent
        settings.lastError = nil
        mirrorSettings = settings
    }

    func scheduleMirror() {
        guard mirrorSettings.isOn, mirrorSettings.bookmark != nil else { return }
        pendingMirror?.cancel()
        pendingMirror = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await self?.mirrorNow()
        }
    }

    /// Writes what's changed since last time, and deletes what the mirror
    /// wrote before that's gone now. Nothing else in the folder is touched.
    @discardableResult
    func mirrorNow() async -> Bool {
        var settings = mirrorSettings
        guard let bookmark = settings.bookmark else { return false }
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            settings.lastError = "The mirror folder can’t be found. Choose it again."
            mirrorSettings = settings
            return false
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        if isStale { try? chooseMirrorFolder(folder) }

        do {
            // Always in the same order, so names made unique ("Notes 2") stay put.
            let items = try context.fetch(FetchDescriptor<Item>())
                .filter { !$0.isTrashed && !$0.isTemplate && !$0.isLocked && !$0.isSealed }
                .sorted { ($0.createdAt, $0.uuid.uuidString) < ($1.createdAt, $1.uuid.uuidString) }
            let entries = try prepareExport(items, everything: false).entries.filter { entry in
                entry.path != BackupManifest.fileName && !entry.path.hasSuffix(".webarchive")
            }
            try await Task.detached(priority: .utility) { try Self.write(entries, to: folder) }.value
            settings.lastMirroredAt = .now
            settings.lastError = nil
        } catch {
            settings.lastError = error.localizedDescription
        }
        mirrorSettings = settings
        return settings.lastError == nil
    }

    nonisolated private static func write(_ entries: [ExportJob.Entry], to folder: URL) throws {
        let manager = FileManager.default
        let listURL = folder.appendingPathComponent(mirrorListName)
        let before = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: listURL))) ?? []
        for entry in entries {
            let destination = folder.appendingPathComponent(entry.path)
            let existing = try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            // Unchanged since it was written: dates are set to the item's own.
            if let existing, abs(existing.timeIntervalSince(entry.modified)) < 1 { continue }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch entry.source {
            case .data(let data):
                try data.write(to: destination, options: .atomic)
            case .file(let file):
                try? manager.removeItem(at: destination)
                try manager.copyItem(at: file, to: destination)
            }
            try? manager.setAttributes([.modificationDate: entry.modified], ofItemAtPath: destination.path)
        }
        let now = Set(entries.map(\.path))
        for old in before where !now.contains(old) {
            let url = folder.appendingPathComponent(old)
            try? manager.removeItem(at: url)
            // And the folder it was in, if that's empty now.
            var parent = url.deletingLastPathComponent()
            while parent.path.count > folder.path.count,
                  (try? manager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? manager.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        }
        try JSONEncoder().encode(now.sorted()).write(to: listURL, options: .atomic)
    }
}
