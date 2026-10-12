import Foundation
import StashCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence, on the device: summarise an item, suggest tags and
/// a category for it, answer questions about it. Nothing leaves the device.
/// Only on iOS and macOS 26 with Apple Intelligence on; otherwise
/// `status` says why, and the side panel leaves it out.
enum Assistant {
    enum Status: Equatable {
        case available
        /// Possible here, but not ready: off in Settings, or still downloading.
        case notReady(String)
        /// This device or system can't.
        case unsupported
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .notReady("Turn on Apple Intelligence in Settings to summarise items and ask about them.")
            case .unavailable(.modelNotReady):
                return .notReady("Apple Intelligence is still getting ready. Try again shortly.")
            case .unavailable:
                return .unsupported
            }
        }
        #endif
        return .unsupported
    }

    /// The model reads a few thousand words at most, so long items are cut short.
    static let textLimit = 6000

    /// What the model reads about an item: its title, notes, and the text
    /// of its page or document.
    static func text(of item: Item) -> String {
        var parts = [item.displayTitle]
        if !item.summary.isEmpty { parts.append(item.summary) }
        if !item.body.isEmpty { parts.append(MarkdownStyling.plainText(item.body)) }
        if !item.extractedText.isEmpty { parts.append(item.extractedText) }
        return String(parts.joined(separator: "\n\n").prefix(textLimit))
    }

    struct Suggestions: Equatable {
        var tags: [String]
        var category: String?
    }

    enum Failure: LocalizedError {
        case unavailable

        var errorDescription: String? { "Apple Intelligence isn’t available on this device." }
    }

    static func summarize(_ text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let session = LanguageModelSession(instructions: """
                You summarise saved notes, web pages and documents for their owner. \
                Write two to four plain sentences saying what it is and what matters in it. \
                No headings, no lists, no preamble.
                """)
            return try await session.respond(to: text).content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw Failure.unavailable
    }

    static func ask(_ question: String, about text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let session = LanguageModelSession(instructions: """
                Answer the question using only the item below. If the item doesn't say, \
                say so plainly. Keep it short.
                """)
            return try await session.respond(to: "Item:\n\(text)\n\nQuestion: \(question)").content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw Failure.unavailable
    }

    /// Tags and a category, preferring ones already in use.
    static func suggest(for text: String, tags: [String], categories: [String]) async throws -> Suggestions {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let session = LanguageModelSession(instructions: """
                You file things in a personal library. Suggest up to four short, lowercase tags \
                and one category for the item. Prefer the existing tags and categories listed \
                when they fit; only invent a new one when none does.
                """)
            let prompt = """
                Existing tags: \(tags.isEmpty ? "none" : tags.joined(separator: ", "))
                Existing categories: \(categories.isEmpty ? "none" : categories.joined(separator: ", "))

                Item:
                \(text)
                """
            let filing = try await session.respond(to: prompt, generating: Filing.self).content
            let cleaned = filing.tags.map(TagName.clean).filter { !$0.isEmpty }
            var seen: Set<String> = []
            let category = filing.category.trimmingCharacters(in: .whitespacesAndNewlines)
            return Suggestions(tags: cleaned.filter { seen.insert(TagName.key($0)).inserted }.prefix(4).map { $0 },
                               category: category.isEmpty ? nil : category)
        }
        #endif
        throw Failure.unavailable
    }
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
struct Filing {
    @Guide(description: "Up to four short lowercase tags, one or two words each")
    var tags: [String]
    @Guide(description: "One category name, ideally an existing one")
    var category: String
}
#endif
