import Foundation
import SwiftData
import StashCore

/// Automatic backups: the whole library, as *Export Everything* makes it,
/// written every day or week to a folder chosen on this device, keeping
/// the newest few. Settings are this device's own, one set per library.
struct AutoBackupSettings: Codable, Equatable {
    var bookmark: Data?
    var folderName = ""
    /// A `RuleSchedule`'s raw value: never, daily or weekly.
    var schedule = RuleSchedule.never.rawValue
    var keep = 7
    var lastBackupAt: Date?
    var lastError: String?
}

extension Library {
    private var autoBackupKey: String { "autoBackup-" + supportFolder.lastPathComponent }

    var autoBackupSettings: AutoBackupSettings {
        get {
            UserDefaults.standard.data(forKey: autoBackupKey)
                .flatMap { try? JSONDecoder().decode(AutoBackupSettings.self, from: $0) } ?? AutoBackupSettings()
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: autoBackupKey)
        }
    }

    /// What backups of this library are called: the main one plainly, others by name.
    private var backupLibraryName: String {
        isMain ? "" : StashStore.shared.current.name
    }

    func chooseBackupFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        var settings = autoBackupSettings
        settings.bookmark = bookmark
        settings.folderName = url.lastPathComponent
        settings.lastError = nil
        autoBackupSettings = settings
    }

    /// The folder, opened; the caller stops accessing it.
    private func backupFolder() -> URL? {
        guard let bookmark = autoBackupSettings.bookmark else { return nil }
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        if isStale { try? chooseBackupFolder(url) }
        return url
    }

    /// The backups in the folder, newest first.
    func automaticBackups() -> [URL] {
        guard let folder = backupFolder() else { return [] }
        defer { folder.stopAccessingSecurityScopedResource() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return BackupRotation.backups(among: names, library: backupLibraryName).map { folder.appendingPathComponent($0) }
    }

    /// Writes a backup now, and deletes the oldest beyond the number kept.
    @discardableResult
    func backUpNow() async -> Bool {
        var settings = autoBackupSettings
        guard let folder = backupFolder() else {
            settings.lastError = "The backup folder can’t be found. Choose it again."
            autoBackupSettings = settings
            return false
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        do {
            let made = try await exportEverything()
            defer { try? FileManager.default.removeItem(at: made.deletingLastPathComponent()) }
            let name = BackupRotation.fileName(library: backupLibraryName, date: .now)
            let destination = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: made, to: destination)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for old in BackupRotation.surplus(among: names, library: backupLibraryName, keep: settings.keep) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
            }
            settings.lastBackupAt = .now
            settings.lastError = nil
        } catch {
            settings.lastError = error.localizedDescription
        }
        autoBackupSettings = settings
        return settings.lastError == nil
    }

    /// From the rules' timer: a backup when one is due.
    func runAutomaticBackupIfDue() async {
        let settings = autoBackupSettings
        guard settings.bookmark != nil,
              (RuleSchedule(rawValue: settings.schedule) ?? .never).isDue(lastRun: settings.lastBackupAt) else { return }
        await backUpNow()
    }

    /// Restores from one of the backups in the folder.
    func restoreAutomaticBackup(_ url: URL) async throws -> RestoreSummary {
        guard let folder = backupFolder() else { throw BackupError.notABackup }
        defer { folder.stopAccessingSecurityScopedResource() }
        return try await restore(from: url)
    }
}
