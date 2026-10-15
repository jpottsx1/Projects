import Foundation

/// Highlights from anywhere in the library, gathered into concepts: the
/// words several highlights share, most widely shared first. Each concept
/// lists the documents its highlights came from, so the map shows which
/// documents speak to the same ideas.
public struct ConceptMap: Equatable {
    public struct Highlight: Equatable {
        public var id: UUID
        public var documentID: UUID
        public var documentTitle: String
        public var text: String
        public var note: String

        public init(id: UUID, documentID: UUID, documentTitle: String, text: String, note: String = "") {
            self.id = id
            self.documentID = documentID
            self.documentTitle = documentTitle
            self.text = text
            self.note = note
        }
    }

    public struct Concept: Equatable {
        public var name: String
        /// In the order they were given.
        public var highlights: [UUID]
        /// In order of first appearance.
        public var documents: [UUID]
    }

    /// Two documents with concepts in common.
    public struct DocumentLink: Equatable {
        public var first: UUID
        public var second: UUID
        public var concepts: [String]
    }

    public var concepts: [Concept]
    /// Highlights that share no concept with any other.
    public var unsorted: [UUID]

    /// `maxConcepts` concepts at most, each with two highlights or more.
    /// Each highlight goes under one concept: the best-shared word it has.
    public static func build(_ highlights: [Highlight], maxConcepts: Int = 12) -> ConceptMap {
        // Each highlight's words, folded so "theory" and "theories" meet.
        var words: [UUID: Set<String>] = [:]
        var spellings: [String: [String: Int]] = [:]
        for highlight in highlights {
            var set: Set<String> = []
            for (word, count) in Keywords.counts(in: highlight.text + " " + highlight.note) {
                let stem = Self.stem(word)
                set.insert(stem)
                spellings[stem, default: [:]][word, default: 0] += count
            }
            words[highlight.id] = set
        }
        var highlightCount: [String: Int] = [:]
        var documents: [String: Set<UUID>] = [:]
        for highlight in highlights {
            for stem in words[highlight.id] ?? [] {
                highlightCount[stem, default: 0] += 1
                documents[stem, default: []].insert(highlight.documentID)
            }
        }
        // Words in most highlights say nothing about any of them.
        let ceiling = highlights.count >= 6 ? Int(Double(highlights.count) * 0.6) : highlights.count
        let candidates = highlightCount.filter { $0.value >= 2 && $0.value <= ceiling }.keys
            .map { stem in (stem, (documents[stem]?.count ?? 0) * 2 + (highlightCount[stem] ?? 0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }

        var assigned: Set<UUID> = []
        var concepts: [Concept] = []
        for (stem, _) in candidates where concepts.count < maxConcepts {
            let taken = highlights.filter { !assigned.contains($0.id) && words[$0.id]?.contains(stem) == true }
            guard taken.count >= 2 else { continue }
            assigned.formUnion(taken.map(\.id))
            var seen: Set<UUID> = []
            let name = spellings[stem]?.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? stem
            concepts.append(Concept(name: name, highlights: taken.map(\.id),
                                    documents: taken.map(\.documentID).filter { seen.insert($0).inserted }))
        }
        return ConceptMap(concepts: concepts, unsorted: highlights.map(\.id).filter { !assigned.contains($0) })
    }

    /// Plurals folded into the singular, roughly.
    static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }

    /// Documents that share concepts, with the concepts, most shared first.
    public var documentLinks: [DocumentLink] {
        var shared: [[UUID]: [String]] = [:]
        for concept in concepts {
            for (index, first) in concept.documents.enumerated() {
                for second in concept.documents.dropFirst(index + 1) {
                    let key = first.uuidString < second.uuidString ? [first, second] : [second, first]
                    shared[key, default: []].append(concept.name)
                }
            }
        }
        return shared.map { DocumentLink(first: $0.key[0], second: $0.key[1], concepts: $0.value) }
            .sorted { $0.concepts.count != $1.concepts.count ? $0.concepts.count > $1.concepts.count
                : ($0.first.uuidString, $0.second.uuidString) < ($1.first.uuidString, $1.second.uuidString) }
    }

    /// The map as a nested list for a mind map: concepts, then the
    /// documents as `[[links]]`, then their highlights.
    public func outline(title: String, highlights: [Highlight], maxLength: Int = 140) -> String {
        let byID = Dictionary(highlights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = ["- " + title]
        func branch(_ name: String, _ ids: [UUID]) {
            lines.append("  - " + name)
            var order: [UUID] = []
            var grouped: [UUID: [Highlight]] = [:]
            for id in ids {
                guard let highlight = byID[id] else { continue }
                if grouped[highlight.documentID] == nil { order.append(highlight.documentID) }
                grouped[highlight.documentID, default: []].append(highlight)
            }
            for document in order {
                guard let first = grouped[document]?.first else { continue }
                lines.append("    - [[" + first.documentTitle + "]]")
                for highlight in grouped[document] ?? [] {
                    lines.append("      - “" + Self.short(highlight.text, maxLength) + "”")
                }
            }
        }
        for concept in concepts { branch(concept.name.capitalized, concept.highlights) }
        if !unsorted.isEmpty { branch("Other Highlights", unsorted) }
        return lines.joined(separator: "\n")
    }

    public static func short(_ text: String, _ maxLength: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > maxLength ? String(flat.prefix(maxLength - 1)) + "…" : flat
    }
}
