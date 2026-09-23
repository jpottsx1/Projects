import SwiftUI

/// A help document, read from a Markdown file that ships with the app.
///
/// Deliberately free of anything about this app. It knows a small subset
/// of Markdown -- headings, paragraphs, bullets, numbered lists, tables,
/// indented blocks, and `code`, **bold** and *dim* inline -- and nothing
/// about what the text says. Another app wanting the same thing copies
/// this file and its own `.md`; there is nothing else to take.
///
/// Written rather than using SwiftUI's own Markdown support, which handles
/// inline styling inside one `Text` and stops there: no headings, no
/// lists, no tables. Those are most of a help document.
struct HelpDocument {

    enum Block: Identifiable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case table(head: [String], rows: [[String]])
        case preformatted(String)

        var id: String {
            switch self {
            case .heading(let level, let text): return "h\(level):\(text)"
            case .paragraph(let text): return "p:\(text.prefix(64))"
            case .bullets(let items): return "u:\(items.first ?? "")"
            case .numbered(let items): return "o:\(items.first ?? "")"
            case .table(let head, _): return "t:\(head.joined())"
            case .preformatted(let text): return "c:\(text.prefix(40))"
            }
        }
    }

    let blocks: [Block]

    /// A document made of blocks already parsed -- what a search returns
    /// when it keeps some of another document's. Written out because
    /// declaring `init(_ text:)` below suppresses the memberwise one.
    init(blocks: [Block]) { self.blocks = blocks }

    /// Load a `.md` from a bundle. Nil rather than a crash: a help file
    /// that failed to copy should cost the reader the guide, not the app.
    ///
    /// Both layouts are tried, because the two ways a Mac app gets built
    /// put the file in different places. SwiftPM's `.copy("Help")` keeps
    /// the folder, so the file is in a `Help` subdirectory of
    /// `Bundle.module`. An Xcode target adds the same files as a group and
    /// they land flat in `Bundle.main`'s Resources. Asking for the
    /// subdirectory first and then without it covers both, and means this
    /// file can be dropped into either kind of app unchanged.
    static func bundled(_ name: String, subdirectory: String? = nil,
                        in bundle: Bundle = .main) -> HelpDocument? {
        let url = bundle.url(forResource: name, withExtension: "md",
                             subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: "md")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return HelpDocument(text)
    }

    init(_ text: String) {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func isRule(_ line: String) -> Bool {
            let kept = line.replacingOccurrences(of: "|", with: "")
                .trimmingCharacters(in: .whitespaces)
            return !kept.isEmpty && kept.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
        func cells(_ line: String) -> [String] {
            line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func marker(_ line: String) -> (ordered: Bool, rest: String)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return (false, String(trimmed.dropFirst(2)))
            }
            if let dot = trimmed.firstIndex(of: "."),
               trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber),
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                return (true, String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
            }
            return nil
        }

        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }

            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: hashes, text: text))
                i += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"),
               i + 1 < lines.count, isRule(lines[i + 1]) {
                let head = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                blocks.append(.table(head: head, rows: rows))
                continue
            }

            if let first = marker(line) {
                var items: [String] = []
                while i < lines.count {
                    if let next = marker(lines[i]), next.ordered == first.ordered {
                        items.append(next.rest)
                        i += 1
                    } else if lines[i].hasPrefix("   "),
                              !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                              !items.isEmpty {
                        // A wrapped continuation of the item above.
                        items[items.count - 1] += " "
                            + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(first.ordered ? .numbered(items) : .bullets(items))
                continue
            }

            if line.hasPrefix("    ") {
                var body: [String] = []
                while i < lines.count,
                      lines[i].hasPrefix("    ")
                        || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    body.append(lines[i].hasPrefix("    ")
                                ? String(lines[i].dropFirst(4)) : "")
                    i += 1
                }
                blocks.append(.preformatted(
                    body.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            var paragraph: [String] = []
            while i < lines.count {
                let next = lines[i]
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || next.hasPrefix("#") || next.hasPrefix("    ")
                    || trimmed.hasPrefix("|") || marker(next) != nil { break }
                paragraph.append(trimmed)
                i += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
        }
        self.blocks = blocks
    }

    /// `**bold**`, `*dim*` and `` `code` `` inline. Anything the parser
    /// does not recognise is shown as written rather than swallowed.
    static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct HelpDocumentView: View {
    let document: HelpDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                switch block {
                case .heading(let level, let text):
                    Text(text)
                        .font(level <= 1 ? .title2 : level == 2 ? .headline : .subheadline)
                        .bold()
                        .foregroundStyle(level >= 3 ? Color.accentColor : .primary)
                        .padding(.top, level <= 1 ? 14 : 8)
                case .paragraph(let text):
                    Text(HelpDocument.styled(text))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .bullets(let items):
                    list(items) { _ in "•" }
                case .numbered(let items):
                    list(items) { "\($0 + 1)." }
                case .table(let head, let rows):
                    table(head: head, rows: rows)
                case .preformatted(let text):
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func list(_ items: [String],
                      marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(marker(index))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    Text(HelpDocument.styled(item))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 2)
    }

    private func table(head: [String], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(head, bold: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Divider()
                row(cells, bold: false)
            }
        }
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ cells: [String], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(HelpDocument.styled(cell))
                    .font(bold ? .caption.bold() : .caption)
                    .foregroundStyle(bold ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
