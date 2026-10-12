import Foundation

/// Asking the whole library a question, as DEVONthink's chat does: find the
/// items most likely to know, take the passage of each that bears on the
/// question, and have the model answer from those alone, citing them as
/// [1], [2]. The model reads only a few thousand words, so passages are short.
public enum LibraryQuestion {
    public struct Source: Equatable {
        public var title: String
        public var passage: String

        public init(title: String, passage: String) {
            self.title = title
            self.passage = passage
        }
    }

    /// Words that ask rather than say what about.
    static let questionWords: Set<String> = [
        "what", "which", "who", "whom", "whose", "when", "where", "why", "how", "does", "did", "do", "is", "are",
        "was", "were", "can", "could", "should", "would", "will", "my", "mine", "me", "i", "about", "tell",
        "find", "show", "list", "any", "anything", "something", "say", "said", "says", "know", "much", "many",
    ]

    /// What to search for: the question's telling words, longest first.
    public static func searchWords(in question: String) -> [String] {
        Keywords.counts(in: question).keys
            .filter { !questionWords.contains($0) && $0.count > 1 }
            .sorted { ($0.count, $0) > ($1.count, $1) }
    }

    /// The stretch of `text` (about `length` characters, whole sentences
    /// where it can) with most of `words` in it; the start when none are.
    public static func passage(in text: String, words: [String], length: Int = 700) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > length else { return clean }
        let sentences = sentences(of: clean)
        let wanted = Set(words.map { $0.lowercased() })
        func score(_ sentence: String) -> Int {
            Keywords.counts(in: sentence).reduce(0) { $0 + (wanted.contains($1.key) ? $1.value : 0) }
        }
        let scores = sentences.map(score)
        // The best window of sentences that fits.
        var best = (score: -1, start: 0, end: 0)
        for start in sentences.indices {
            var total = 0, characters = 0, end = start
            while end < sentences.count, characters + sentences[end].count <= length || end == start {
                total += scores[end]
                characters += sentences[end].count + 1
                end += 1
            }
            if total > best.score { best = (total, start, end) }
        }
        let joined = sentences[best.start..<best.end].joined(separator: " ")
        return joined.count > length ? String(joined.prefix(length)) + "…" : joined
    }

    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character), current.count > 1 {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }

    public static let instructions = """
        You answer questions about the owner's personal library of notes, saved web pages and documents. \
        Use only the numbered sources given with the question. Cite the sources you use in square brackets, \
        like [1] or [2][3], right after what they support. If the sources don't answer the question, say \
        that the library doesn't seem to say, and don't guess. Be brief and plain.
        """

    /// The question with its numbered sources.
    public static func prompt(question: String, sources: [Source]) -> String {
        var parts = ["Sources:"]
        for (number, source) in sources.enumerated() {
            parts.append("[\(number + 1)] \(source.title)\n\(source.passage)")
        }
        parts.append("Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))")
        return parts.joined(separator: "\n\n")
    }

    /// The sources an answer cites, by number, in the order first cited.
    public static func citations(in answer: String, sourceCount: Int) -> [Int] {
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+(?:\s*,\s*\d+)*)\]"#)
        var seen: [Int] = []
        let string = answer as NSString
        for match in pattern.matches(in: answer, range: NSRange(location: 0, length: string.length)) {
            for piece in string.substring(with: match.range(at: 1)).split(separator: ",") {
                if let number = Int(piece.trimmingCharacters(in: .whitespaces)), (1...max(sourceCount, 1)).contains(number),
                   !seen.contains(number) {
                    seen.append(number)
                }
            }
        }
        return seen
    }
}
