import Foundation

/// Several notes made into one, each under its own heading, as
/// DEVONthink's *Merge* does.
public enum NoteMerge {
    public static func merge(_ notes: [(title: String, body: String)]) -> String {
        notes.map { note in
            let title = note.title.trimmingCharacters(in: .whitespaces)
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("## " + (title.isEmpty ? "Untitled" : title)) + (body.isEmpty ? "" : "\n\n" + body)
        }
        .joined(separator: "\n\n")
    }
}
