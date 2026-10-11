import Foundation

/// What a saved link remembers of its page: a title and summary to show, and
/// the page's words, so searching finds links by what is on the page.
public struct PageText: Equatable {
    public var title: String?
    public var summary: String?
    public var text: String

    public init(title: String? = nil, summary: String? = nil, text: String = "") {
        self.title = title
        self.summary = summary
        self.text = text
    }
}

/// Pulls readable text out of a web page. Regular expressions rather than a
/// real HTML parser: the result only feeds search and a one-line summary, so
/// "mostly right" is enough.
public enum HTMLText {
    public static func extract(from html: String, maxLength: Int = 100_000) -> PageText {
        var page = PageText()

        if let title = firstCapture(#"<title[^>]*>(.*?)</title>"#, in: html) {
            page.title = nonEmpty(clean(title))
        }

        for tag in matches(#"<meta\s[^>]*>"#, in: html) {
            let attributes = self.attributes(of: tag)
            let name = (attributes["name"] ?? attributes["property"] ?? "").lowercased()
            guard let content = attributes["content"].map(clean), !content.isEmpty else { continue }
            switch name {
            case "description", "og:description":
                if page.summary == nil { page.summary = content }
            case "og:title":
                if page.title == nil { page.title = content }
            default:
                break
            }
        }

        var body = html
        for pattern in [#"<!--.*?-->"#,
                        #"<(script|style|noscript|svg|head|template)\b[^>]*>.*?</\1\s*>"#] {
            body = replacing(pattern, in: body, with: " ")
        }
        body = replacing(#"<[^>]+>"#, in: body, with: " ")
        let text = clean(body)
        page.text = text.count > maxLength ? String(text.prefix(maxLength)) : text
        return page
    }

    /// Named entities that turn up in ordinary pages, plus every numeric one.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
            "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
            "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        ]
        let regex = try! NSRegularExpression(pattern: #"&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String($0) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst(), radix: 10).flatMap { Unicode.Scalar($0) }.map { String($0) }
            } else {
                replacement = named[name.lowercased()]
            }
            guard let replacement else { continue }
            result += text[cursor..<whole.lowerBound]
            result += replacement
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Helpers

    private static let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]

    /// Entities decoded, all whitespace runs made single spaces.
    private static func clean(_ text: String) -> String {
        decodeEntities(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }

    /// `<meta name="x" content='y'>` -> ["name": "x", "content": "y"]
    private static func attributes(of tag: String) -> [String: String] {
        let regex = try! NSRegularExpression(
            pattern: #"([a-zA-Z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: options)
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let valueRange = Range(match.range(at: 2), in: tag) ?? Range(match.range(at: 3), in: tag)
            result[tag[nameRange].lowercased()] = valueRange.map { String(tag[$0]) } ?? ""
        }
        return result
    }
}
