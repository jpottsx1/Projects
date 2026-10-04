import Foundation

/// What a run produced, in a shape a host embedding `LoudnessLabView` can
/// act on without reaching into `Manifest` -- the one place this package's
/// own type crosses into a host's.
///
/// Only posted for a run that did not ask the tool to replace originals
/// itself (`replaceOriginals: false` in `Engine.run`). That kind of run
/// leaves both an original and a processed file behind for a host to
/// compare and adopt; a `--replace-originals` run has already done that
/// job itself and has no separate original left to hand back.
public struct LoudnessRun: Codable, Sendable {
    public struct Output: Codable, Sendable, Equatable {
        public let source: URL
        public let processed: URL
        public let name: String
    }

    public let date: Date
    public let outputs: [Output]
}

extension Notification.Name {
    /// Posted with a `LoudnessRun` as the notification's `object` once a
    /// compare run (not one that replaced originals itself) has written
    /// its files.
    public static let loudnessLabRunFinished = Notification.Name("loudnesslab.runFinished")
}

extension LoudnessRun {
    /// Reads the run back out of a `.loudnessLabRunFinished` notification.
    public static func from(_ note: Notification) -> LoudnessRun? {
        note.object as? LoudnessRun
    }

    private static var persistedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoudnessLab/last-run.json")
    }

    /// The run from just before the app last quit, for a window opened
    /// after a relaunch that hasn't seen a run of its own yet -- so a run
    /// finished just before quitting is still adoptable afterward.
    public static func latest() -> LoudnessRun? {
        guard let data = try? Data(contentsOf: persistedURL) else { return nil }
        return try? JSONDecoder().decode(LoudnessRun.self, from: data)
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.persistedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: Self.persistedURL)
    }
}
