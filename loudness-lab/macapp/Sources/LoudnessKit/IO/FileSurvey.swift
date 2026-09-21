import Foundation

/// Walking a library once, reporting what was found AND what was passed over.
///
/// A port of `decode.survey`. The counting of what was skipped is the point:
/// a library that comes back smaller than expected is nearly always an
/// extension not on the list, a folder that could not be read, or a path
/// that named a single file, and saying which beats silently finding
/// nothing.
public enum FileSurvey {

    public struct Result: Sendable {
        public var audio: [URL] = []
        public var skipped: [String: Int] = [:]
        public var folders = 0
        public var errors: [String] = []
        public var singleFile = false
    }

    public static func survey(_ root: URL) -> Result {
        var result = Result()
        let manager = FileManager.default

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            result.errors.append("\(root.path): no such file or folder")
            return result
        }
        if !isDirectory.boolValue {
            result.singleFile = true
            let suffix = root.pathExtension.lowercased()
            if AudioDecoder.audioSuffixes.contains(suffix) { result.audio = [root] }
            else if !suffix.isEmpty { result.skipped[suffix] = 1 }
            return result
        }

        // Symlinks are followed, because a library folder is quite often a
        // link to somewhere else; resolved paths are remembered so a cycle
        // cannot loop forever.
        var seen = Set<String>()
        var queue = [root]
        while let folder = queue.popLast() {
            let real = folder.resolvingSymlinksInPath().path
            if seen.contains(real) { continue }
            seen.insert(real)
            result.folders += 1

            let contents: [URL]
            do {
                contents = try manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [])
            } catch {
                result.errors.append("\(folder.path): \(error.localizedDescription)")
                continue
            }

            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                // Dot-directories are .Trashes and .Spotlight-V100, which are
                // on every removable volume; dot-files are AppleDouble
                // resource forks like ._Track.mp3, which are not audio.
                if name.hasPrefix(".") { continue }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    queue.append(entry)
                    continue
                }
                let suffix = entry.pathExtension.lowercased()
                if AudioDecoder.audioSuffixes.contains(suffix) { result.audio.append(entry) }
                else if !suffix.isEmpty { result.skipped[suffix, default: 0] += 1 }
            }
        }
        result.audio.sort { $0.path < $1.path }
        return result
    }

    public static func findAudio(_ root: URL) -> [URL] { survey(root).audio }
}
