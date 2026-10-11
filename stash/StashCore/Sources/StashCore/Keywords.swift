import Foundation

/// The words that say most about an item, for finding others like it
/// ("See Also"): words it uses a lot that few other items use.
public enum Keywords {
    /// How often each word worth considering appears. Words are lowercased;
    /// short words, numbers and common English words are left out. Only the
    /// first `limit` characters are read, so a long PDF doesn't take forever.
    public static func counts(in text: String, limit: Int = 50_000) -> [String: Int] {
        var counts: [String: Int] = [:]
        text.prefix(limit).enumerateSubstrings(in: text.prefix(limit).startIndex..., options: .byWords) { word, _, _, _ in
            guard let word = word?.lowercased(), word.count >= 3, word.count <= 40,
                  word.contains(where: \.isLetter), !stopWords.contains(word) else { return }
            counts[word, default: 0] += 1
        }
        return counts
    }

    /// The `limit` best words: frequent in this item (`counts`), and rare
    /// across the library. `documentFrequency` says how many items contain
    /// a word, this one included; words no other item has can't find
    /// anything, and words nearly every item has say nothing, so both are
    /// skipped.
    public static func best(_ counts: [String: Int], documentFrequency: (String) -> Int,
                            documentCount: Int, limit: Int = 12) -> [String] {
        guard documentCount > 1 else { return [] }
        // Look up the frequent words first; the rest rarely make the cut.
        let candidates = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(60)
        var scored: [(word: String, score: Double)] = []
        for (word, count) in candidates {
            let frequency = documentFrequency(word)
            guard frequency >= 2, Double(frequency) <= Double(documentCount) * 0.5 || documentCount < 6 else { continue }
            let rarity = log(Double(documentCount) / Double(frequency))
            guard rarity > 0 else { continue }
            scored.append((word, (1 + log(Double(count))) * rarity))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }
            .prefix(limit)
            .map(\.word)
    }

    static let stopWords: Set<String> = [
        "about", "above", "after", "again", "against", "all", "also", "am", "an", "and", "any", "are",
        "aren't", "because", "been", "before", "being", "below", "between", "both", "but", "can",
        "cannot", "could", "couldn't", "did", "didn't", "does", "doesn't", "doing", "don't", "down",
        "during", "each", "even", "ever", "every", "few", "for", "from", "further", "get", "gets", "got",
        "had", "hadn't", "has", "hasn't", "have", "haven't", "having", "her", "here", "hers", "herself",
        "him", "himself", "his", "how", "however", "http", "https", "into", "isn't", "it's", "its",
        "itself", "just", "let's", "like", "made", "make", "many", "may", "more", "most", "much", "must",
        "mustn't", "myself", "never", "new", "nor", "not", "now", "off", "once", "one", "only", "other",
        "ought", "our", "ours", "ourselves", "out", "over", "own", "same", "say", "says", "said", "see",
        "shan't", "she", "should", "shouldn't", "since", "some", "still", "such", "than", "that",
        "that's", "the", "their", "theirs", "them", "themselves", "then", "there", "there's", "these",
        "they", "they'd", "they'll", "they're", "they've", "this", "those", "though", "through", "too",
        "two", "under", "until", "upon", "use", "used", "using", "very", "via", "was", "wasn't", "way",
        "we'd", "we'll", "we're", "we've", "well", "were", "weren't", "what", "what's", "when", "where",
        "which", "while", "who", "whom", "why", "will", "with", "won't", "would", "wouldn't", "www",
        "yet", "you", "you'd", "you'll", "you're", "you've", "your", "yours", "yourself", "yourselves",
    ]
}
