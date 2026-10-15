import Foundation

/// MarginNote's study notebooks, the parts that don't need the app: a
/// notebook's cards as a tree (each card an excerpt or a heading, under
/// another or at the top), and where cards' titles turn up in a document.
public enum StudyMap {
    public struct Card: Equatable {
        public var id: UUID
        public var parent: UUID?
        public var order: Int
        public var title: String
        public var excerpt: String

        public init(id: UUID, parent: UUID?, order: Int, title: String, excerpt: String = "") {
            self.id = id
            self.parent = parent
            self.order = order
            self.title = title
            self.excerpt = excerpt
        }

        /// What a card is called: its title, or failing that its excerpt.
        public var label: String {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? ConceptMap.short(excerpt, 80) : name
        }
    }

    /// Cards under `parent` (nil for the top), in order. A card whose
    /// parent isn't among them counts as at the top.
    public static func children(of parent: UUID?, in cards: [Card]) -> [Card] {
        let ids = Set(cards.map(\.id))
        return cards.filter { card in
            parent == nil ? (card.parent == nil || !ids.contains(card.parent!)) : card.parent == parent
        }
        .sorted { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }
    }

    /// Every card with how deep it is, top to bottom, as an outline shows them.
    public static func flattened(_ cards: [Card]) -> [(card: Card, depth: Int)] {
        var result: [(Card, Int)] = []
        var seen: Set<UUID> = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for card in children(of: parent, in: cards) where seen.insert(card.id).inserted {
                result.append((card, depth))
                walk(card.id, depth + 1)
            }
        }
        walk(nil, 0)
        return result
    }

    /// The cards as a mind map under `title`, and which card each node is.
    public static func mindMap(_ cards: [Card], title: String) -> (map: MindMap, cards: [[Int]: UUID]) {
        var paths: [[Int]: UUID] = [:]
        var seen: Set<UUID> = []
        func nodes(under parent: UUID?, path: [Int]) -> [MindMap.Node] {
            children(of: parent, in: cards).filter { seen.insert($0.id).inserted }.enumerated().map { index, card in
                paths[path + [index]] = card.id
                return MindMap.Node(title: card.label, children: nodes(under: card.id, path: path + [index]))
            }
        }
        let root = MindMap.Node(title: title, children: nodes(under: nil, path: []))
        return (MindMap(root: root), paths)
    }

    /// Whether `card` can go under `target` (nil for the top): not under
    /// itself, nor anything inside it.
    public static func canMove(_ card: UUID, under target: UUID?, in cards: [Card]) -> Bool {
        guard let target else { return true }
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: UUID? = target
        var steps = 0
        while let current = next, steps <= cards.count {
            if current == card { return false }
            next = byID[current]?.parent
            steps += 1
        }
        return true
    }

    /// The cards as a Markdown outline: titles, and excerpts quoted.
    public static func outline(_ cards: [Card], title: String) -> String {
        var lines = ["# " + title, ""]
        for (card, depth) in flattened(cards) {
            let indent = String(repeating: "  ", count: depth)
            let name = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = ConceptMap.short(card.excerpt, 400)
            switch (name.isEmpty, excerpt.isEmpty) {
            case (false, true): lines.append(indent + "- **" + name + "**")
            case (true, false): lines.append(indent + "- “" + excerpt + "”")
            case (false, false): lines.append(indent + "- **" + name + "**: “" + excerpt + "”")
            case (true, true): lines.append(indent + "- …")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// MarginNote's title links: where the titles of cards made earlier turn up
/// in a document, page by page.
public enum TitleLinks {
    public struct Match: Equatable {
        public var title: String
        /// Pages (from 0) it's on, in order.
        public var pages: [Int]
    }

    /// Whole words, ignoring case; titles under three letters are left out.
    public static func find(_ titles: [String], in pages: [String]) -> [Match] {
        var seen: Set<String> = []
        let wanted = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && seen.insert($0.lowercased()).inserted }
        let lowered = pages.map { $0.lowercased() }
        return wanted.compactMap { title in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: title.lowercased()) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let found = lowered.indices.filter { index in
                regex.firstMatch(in: lowered[index], range: NSRange(lowered[index].startIndex..., in: lowered[index])) != nil
            }
            return found.isEmpty ? nil : Match(title: title, pages: found)
        }
        .sorted { $0.pages.count != $1.pages.count ? $0.pages.count > $1.pages.count : $0.title < $1.title }
    }
}
