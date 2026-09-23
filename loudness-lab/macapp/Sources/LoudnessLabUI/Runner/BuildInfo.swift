import Foundation
import LoudnessKit

/// When this copy of the app was built, and what it found to work with.
///
/// It exists because "are the changes in the app yet?" has been asked
/// several times and could not be answered from the screen. Code reaches a
/// machine by being pulled and rebuilt, and nothing in the window said
/// whether either had happened -- so a fix pushed an hour ago and a build
/// from yesterday looked exactly alike.
///
/// The build time is taken from the executable's own timestamp rather than
/// stamped in at compile time, because that works the same whether the app
/// was launched from Xcode, from `swift run`, or from the bundle, with no
/// build step to remember.
enum BuildInfo {

    static var builtAt: Date? {
        let candidates = [Bundle.main.executableURL,
                          URL(fileURLWithPath: CommandLine.arguments.first ?? "")]
        for url in candidates.compactMap({ $0 }) {
            if let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path),
               let date = attributes[.modificationDate] as? Date {
                return date
            }
        }
        return nil
    }

    /// One line for the top of the log, so every run says what produced it.
    static var summary: String {
        var parts = ["Loudness Lab"]
        if let builtAt {
            let stamp = DateFormatter()
            stamp.dateFormat = "d MMM HH:mm"
            parts.append("built \(stamp.string(from: builtAt))")
            let age = Date().timeIntervalSince(builtAt)
            // The point of the line: an old build is the usual reason a fix
            // appears to have done nothing.
            if age > 6 * 3600 {
                parts.append("(\(Int(age / 3600))h ago — pull and rebuild if "
                             + "you are expecting a change)")
            }
        }
        parts.append(CLI.locate().map { "CLI: \($0.path)" } ?? "CLI: not found")
        return parts.joined(separator: " · ")
    }
}
