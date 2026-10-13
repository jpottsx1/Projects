import Foundation

/// A mind map, kept as a note's nested Markdown list: the first top-level
/// item is the centre, and each item's children branch from it. So a mind
/// map reads as an outline anywhere else, and searches and syncs like text.
public struct MindMap: Equatable {
    public struct Node: Equatable, Identifiable {
        /// Its place: the indexes down from the root (the root is []).
        public var id: [Int] { path }
        public var path: [Int]
        public var title: String
        public var children: [Node]

        public init(title: String, children: [Node] = [], path: [Int] = []) {
            self.title = title
            self.children = children
            self.path = path
        }
    }

    public var root: Node

    public init(root: Node) {
        self.root = root
        renumber()
    }

    // MARK: - Text

    /// Reads a nested list ("- ", "* ", "+ " or "1. ", indented by any
    /// amount); anything else is left out. Several top-level items become
    /// children of the first.
    public init(markdown: String) {
        var stack: [(indent: Int, node: Node)] = []
        var tops: [Node] = []
        func close(to indent: Int) {
            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
                if stack.isEmpty { tops.append(last.node) } else { stack[stack.count - 1].node.children.append(last.node) }
            }
        }
        for line in markdown.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let body = line.trimmingCharacters(in: .whitespaces)
            var title: String?
            for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) { title = String(body.dropFirst(2)) }
            if title == nil, let dot = body.firstIndex(of: "."), body[..<dot].allSatisfy(\.isNumber), !body[..<dot].isEmpty,
               body[body.index(after: dot)...].hasPrefix(" ") {
                title = String(body[body.index(dot, offsetBy: 2)...])
            }
            guard let title else { continue }
            close(to: indent)
            stack.append((indent, Node(title: title.trimmingCharacters(in: .whitespaces))))
        }
        close(to: -1)
        var root = tops.first ?? Node(title: "Central Idea")
        root.children += tops.dropFirst()
        self.init(root: root)
    }

    /// The map as a nested list, two spaces a level.
    public var markdown: String {
        var lines: [String] = []
        func write(_ node: Node, depth: Int) {
            lines.append(String(repeating: "  ", count: depth) + "- " + node.title)
            for child in node.children { write(child, depth: depth + 1) }
        }
        write(root, depth: 0)
        return lines.joined(separator: "\n")
    }

    // MARK: - Changes

    public func node(at path: [Int]) -> Node? {
        var node = root
        for index in path {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    private mutating func change(_ path: [Int], _ body: (inout Node) -> Void) {
        func walk(_ node: inout Node, _ rest: ArraySlice<Int>) {
            guard let first = rest.first else { return body(&node) }
            guard node.children.indices.contains(first) else { return }
            walk(&node.children[first], rest.dropFirst())
        }
        walk(&root, path[...])
        renumber()
    }

    /// Adds a child at the end of a node's children; gives its path.
    @discardableResult
    public mutating func addChild(to path: [Int], title: String) -> [Int] {
        var newIndex = 0
        change(path) { node in
            node.children.append(Node(title: title))
            newIndex = node.children.count - 1
        }
        return path + [newIndex]
    }

    /// Adds a node just after this one, under the same parent; the root
    /// gets a child instead. Gives its path.
    @discardableResult
    public mutating func addSibling(after path: [Int], title: String) -> [Int] {
        guard let last = path.last else { return addChild(to: [], title: title) }
        let parent = Array(path.dropLast())
        change(parent) { $0.children.insert(Node(title: title), at: last + 1) }
        return parent + [last + 1]
    }

    public mutating func rename(_ path: [Int], to title: String) {
        change(path) { $0.title = title }
    }

    /// Takes a node and its branch away; the root stays.
    public mutating func delete(_ path: [Int]) {
        guard let last = path.last else { return }
        change(Array(path.dropLast())) { node in
            if node.children.indices.contains(last) { node.children.remove(at: last) }
        }
    }

    /// Moves a node's branch to the end of another node's children. Not
    /// into itself or its own branch.
    @discardableResult
    public mutating func move(_ path: [Int], under target: [Int]) -> [Int]? {
        guard !path.isEmpty, !target.starts(with: path), let moving = node(at: path) else { return nil }
        delete(path)
        // Taking it out may have shifted the target's path.
        var adjusted = target
        if path.count <= target.count, Array(target.prefix(path.count - 1)) == Array(path.dropLast()),
           target[path.count - 1] > path[path.count - 1] {
            adjusted[path.count - 1] -= 1
        }
        var newIndex = 0
        change(adjusted) { node in
            var branch = moving
            branch.path = []
            node.children.append(branch)
            newIndex = node.children.count - 1
        }
        return adjusted + [newIndex]
    }

    private mutating func renumber() {
        func number(_ node: inout Node, _ path: [Int]) {
            node.path = path
            for index in node.children.indices { number(&node.children[index], path + [index]) }
        }
        number(&root, [])
    }

    // MARK: - Layout

    public struct Placed: Equatable {
        public var path: [Int]
        public var title: String
        /// Depth across, and row down (in leaf rows; a parent sits in the
        /// middle of its children).
        public var column: Int
        public var row: Double
        public var parent: [Int]?
    }

    /// Every node's place: the centre at the left, branches to the right,
    /// each leaf a row of its own.
    public func layout() -> [Placed] {
        var placed: [Placed] = []
        var nextRow = 0.0
        func place(_ node: Node, column: Int, parent: [Int]?) -> Double {
            let row: Double
            if node.children.isEmpty {
                row = nextRow
                nextRow += 1
            } else {
                let rows = node.children.map { place($0, column: column + 1, parent: node.path) }
                row = ((rows.first ?? 0) + (rows.last ?? 0)) / 2
            }
            placed.append(Placed(path: node.path, title: node.title, column: column, row: row, parent: parent))
            return row
        }
        _ = place(root, column: 0, parent: nil)
        return placed.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }
}
