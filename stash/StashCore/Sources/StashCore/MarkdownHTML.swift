import Foundation

/// A note as HTML, for printing and saving as PDF.
public enum MarkdownHTML {
    /// The note's blocks as HTML, without `<html>` or `<body>` around them.
    /// `picture` turns a picture's source into what the `<img>` should load
    /// (a stored attachment as a data URL, say); nil leaves it out.
    public static func render(_ text: String, picture: (String) -> String? = { $0 }) -> String {
        var html: [String] = []
        var openList: String?
        func closeList() {
            if let list = openList { html.append("</\(list)>") }
            openList = nil
        }
        func list(_ tag: String) {
            if openList != tag {
                closeList()
                html.append("<\(tag)>")
                openList = tag
            }
        }
        for block in MarkdownBlocks.parse(text) {
            switch block {
            case .bullet(_, let text):
                list("ul")
                html.append("<li>\(inline(text))</li>")
            case .task(_, let done, let text, _):
                list("ul")
                html.append("<li class=\"task\">\(done ? "☑" : "☐") \(inline(text))</li>")
            case .numbered(_, let number, let text):
                list("ol")
                html.append("<li value=\"\(number)\">\(inline(text))</li>")
            default:
                closeList()
                switch block {
                case .heading(let level, let text): html.append("<h\(level)>\(inline(text))</h\(level)>")
                case .paragraph(let text): html.append("<p>\(inline(text))</p>")
                case .quote(let text): html.append("<blockquote>\(inline(text))</blockquote>")
                case .code(_, let text): html.append("<pre><code>\(escape(text))</code></pre>")
                case .rule: html.append("<hr>")
                case .image(let alt, let source):
                    if let resolved = picture(source) {
                        let sized = MarkdownBlocks.pictureSize(alt)
                        let width = sized.width.map { " width=\"\($0)\"" } ?? ""
                        html.append("<p><img src=\"\(escape(resolved))\" alt=\"\(escape(sized.alt))\"\(width)></p>")
                    }
                case .toggle(let title, let body, _):
                    html.append("<details><summary>\(inline(title))</summary>\(render(body, picture: picture))</details>")
                case .table(let header, let rows):
                    let head = header.map { "<th>\(inline($0))</th>" }.joined()
                    let body = rows.map { row in "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined()
                    html.append("<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>")
                default: break
                }
            }
        }
        closeList()
        return html.joined(separator: "\n")
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]|]+)\\|([^\\[\\]]+)\\]\\]"), "<em class=\"wiki\">$2</em>"),
        (try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]|]+)\\]\\]"), "<em class=\"wiki\">$1</em>"),
        (try! NSRegularExpression(pattern: "\\[([^\\[\\]]+)\\]\\(([^()\\s]+)\\)"), "<a href=\"$2\">$1</a>"),
        (try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1"), "<strong>$2</strong>"),
        (try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~"), "<del>$1</del>"),
        (try! NSRegularExpression(pattern: "(?<![\\*\\w])(\\*|_)(?=[^\\s\\*_])(.+?)(?<=[^\\s\\*_])\\1(?![\\*\\w])"), "<em>$2</em>"),
    ]
    private static let codePattern = try! NSRegularExpression(pattern: "`([^`]+)`")

    /// Inline Markdown as HTML. Code spans are left exactly as written.
    public static func inline(_ text: String) -> String {
        var pieces: [String] = []
        var last = text.startIndex
        let string = text as NSString
        for match in codePattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            guard let whole = Range(match.range, in: text), let code = Range(match.range(at: 1), in: text) else { continue }
            pieces.append(formatted(String(text[last..<whole.lowerBound])))
            pieces.append("<code>" + escape(String(text[code])) + "</code>")
            last = whole.upperBound
        }
        pieces.append(formatted(String(text[last...])))
        return pieces.joined()
    }

    private static func formatted(_ text: String) -> String {
        var html = escape(text)
        for (pattern, template) in rules {
            html = pattern.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                                    withTemplate: template)
        }
        return html
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
