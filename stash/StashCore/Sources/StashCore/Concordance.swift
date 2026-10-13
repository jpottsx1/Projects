import Foundation

/// DEVONthink's concordance: the words used across some items, how often,
/// and in how many of them.
public enum Concordance {
    public struct Word: Equatable {
        public var word: String
        public var count: Int
        /// How many of the texts have it.
        public var documents: Int
    }

    /// Words of three letters or more, lowercased, leaving out numbers and
    /// common English words unless `keepsCommonWords`. Most used first.
    public static func words(in texts: [String], minimumLength: Int = 3, keepsCommonWords: Bool = false) -> [Word] {
        var counts: [String: Int] = [:]
        var documents: [String: Int] = [:]
        for text in texts {
            var seen: Set<String> = []
            text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { word, _, _, _ in
                guard let word else { return }
                let lowered = word.lowercased()
                guard lowered.count >= minimumLength, lowered.contains(where: \.isLetter),
                      keepsCommonWords || !commonWords.contains(lowered) else { return }
                counts[lowered, default: 0] += 1
                if seen.insert(lowered).inserted { documents[lowered, default: 0] += 1 }
            }
        }
        return counts.map { Word(word: $0.key, count: $0.value, documents: documents[$0.key] ?? 0) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
    }

    /// A size from 0 to 1 for each word in a cloud: by its count's
    /// logarithm, so one very common word doesn't dwarf the rest.
    public static func weights(_ words: [Word]) -> [String: Double] {
        guard let most = words.map(\.count).max(), let least = words.map(\.count).min() else { return [:] }
        let top = log(Double(most)), bottom = log(Double(least))
        return Dictionary(words.map { word in
            (word.word, top == bottom ? 1 : (log(Double(word.count)) - bottom) / (top - bottom))
        }, uniquingKeysWith: { first, _ in first })
    }

    static let commonWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "him", "his", "how", "its", "may", "new", "now", "old", "see", "two", "way", "who", "did", "get", "let",
        "put", "say", "she", "too", "use", "that", "with", "have", "this", "will", "your", "from", "they", "know", "want",
        "been", "good", "much", "some", "time", "very", "when", "come", "here", "just", "like", "long", "make", "many",
        "more", "only", "over", "such", "take", "than", "them", "well", "were", "what", "which", "their", "there",
        "these", "those", "would", "could", "should", "about", "after", "again", "also", "because", "before", "being",
        "between", "both", "each", "into", "most", "other", "same", "then", "through", "under", "until", "while",
        "where", "why", "does", "doing", "down", "during", "few", "further", "own", "off", "once", "yours", "itself",
        "myself", "himself", "herself", "themselves", "ourselves", "what's", "it's", "don't", "can't", "i'm", "you're",
        "isn't", "wasn't", "didn't", "won't", "http", "https", "www", "com",
    ]
}
