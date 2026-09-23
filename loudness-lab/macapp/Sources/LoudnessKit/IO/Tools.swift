import Foundation

/// Finding the command-line tools, on a PATH a GUI app can actually see.
///
/// A program launched from Finder or Xcode does not inherit the shell's
/// PATH. It gets roughly /usr/bin:/bin:/usr/sbin:/sbin and nothing a
/// .zprofile added, so a Homebrew ffmpeg is on the PATH in Terminal and
/// invisible here -- the same command on the same machine giving a
/// different answer, which is a confusing way to be told to install
/// something you already have.
///
/// In the kit rather than the app because the writer needs ffmpeg too, and
/// two copies of this list would drift.
public enum Tools {

    public static let extraDirectories = [
        "/opt/homebrew/bin",        // Apple silicon Homebrew
        "/usr/local/bin",           // Intel Homebrew, and most installers
        "/opt/local/bin",           // MacPorts
        "/opt/homebrew/sbin",
    ]

    /// The inherited environment with those appended -- appended, so a PATH
    /// that was inherited properly still wins.
    public static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let already = Set(existing.split(separator: ":").map(String.init))
        let missing = extraDirectories.filter {
            !already.contains($0) && FileManager.default.fileExists(atPath: $0)
        }
        if !missing.isEmpty {
            environment["PATH"] = ([existing] + missing).joined(separator: ":")
        }
        return environment
    }

    public static func find(_ name: String) -> URL? {
        for directory in (environment()["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path,
                                              isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Whether this ffmpeg has a named encoder.
    ///
    /// Asked once. macOS builds usually carry `aac_at`, Apple's own AAC
    /// encoder, which is better than ffmpeg's native one at the bitrates
    /// that matter -- but it is a build option, not a guarantee, so it has
    /// to be checked rather than assumed.
    public static func hasEncoder(_ name: String) -> Bool {
        if let known = encoderCache.value(name) { return known }
        var found = false
        if let ffmpeg = find("ffmpeg"),
           let listing = try? run(ffmpeg, ["-hide_banner", "-encoders"]) {
            found = listing.contains(" \(name) ")
        }
        encoderCache.set(name, found)
        return found
    }

    private static let encoderCache = EncoderCache()

    private final class EncoderCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Bool] = [:]
        func value(_ name: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            return known[name]
        }
        func set(_ name: String, _ value: Bool) {
            lock.lock(); known[name] = value; lock.unlock()
        }
    }

    /// Run one to completion, returning its stderr if it failed.
    @discardableResult
    public static func run(_ tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment()
        let errors = Pipe()
        let output = Pipe()
        process.standardError = errors
        process.standardOutput = output
        try process.run()
        // Read before waiting: a pipe that fills up blocks the child, and a
        // child that is blocked never exits, which is a deadlock that only
        // shows itself on the files with the most to say.
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        if process.terminationStatus != 0 {
            throw Failure("\(tool.lastPathComponent) failed: "
                          + text.split(separator: "\n").suffix(3)
                              .joined(separator: " "))
        }
        return text
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }
}
