import Foundation

/// An email message (RFC 5322 and MIME), as saved in a .eml file or one of
/// the messages in an .mbox: who it's from and to, when, the subject, the
/// text (plain and HTML) and the attachments.
public struct MIMEMessage {
    public struct Address: Equatable {
        public var name: String
        public var email: String

        /// The name if there is one, else the address.
        public var display: String { name.isEmpty ? email : name }
    }

    public struct Attachment: Equatable {
        public var fileName: String
        public var mimeType: String
        public var data: Data
        /// For pictures the HTML shows by `cid:`.
        public var contentID: String?
        public var isInline: Bool
    }

    /// Unfolded, in order, values as written (encoded words not decoded).
    public private(set) var headers: [(name: String, value: String)] = []
    public private(set) var textBody: String?
    public private(set) var htmlBody: String?
    public private(set) var attachments: [Attachment] = []

    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard let entity = Entity(bytes) else { return nil }
        headers = entity.headers
        guard headers.contains(where: { ["from", "subject", "date", "to", "message-id"].contains($0.name.lowercased()) }) else {
            return nil
        }
        collect(entity)
    }

    // MARK: - Headers

    /// A header's value, with encoded words (`=?utf-8?B?...?=`) decoded.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map { Self.decodeWords($0.value).trimmingCharacters(in: .whitespaces) }
    }

    public var subject: String { header("Subject") ?? "" }
    public var from: [Address] { header("From").map(Self.addresses) ?? [] }
    public var to: [Address] { header("To").map(Self.addresses) ?? [] }
    public var cc: [Address] { header("Cc").map(Self.addresses) ?? [] }

    public var date: Date? {
        guard var text = header("Date") else { return nil }
        // "(PDT)" and the like after the zone.
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        return FeedParser.date(text.trimmingCharacters(in: .whitespaces))
    }

    /// Without the angle brackets.
    public var messageID: String? {
        header("Message-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    /// The text to read and search: the plain text, or the HTML's words.
    public var plainText: String {
        if let textBody, !textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return textBody }
        return htmlBody.map { HTMLMarkdown.convert($0) } ?? ""
    }

    // MARK: - Parts

    private mutating func collect(_ entity: Entity) {
        let type = entity.contentType
        if type.value.hasPrefix("multipart/"), let boundary = type.parameters["boundary"] {
            for part in entity.parts(boundary: boundary) { collect(part) }
            return
        }
        let disposition = entity.header("Content-Disposition").map(Self.parameters)
        let name = disposition?.parameters["filename"] ?? type.parameters["name"]
        let isAttachment = disposition?.value == "attachment" || (name != nil && !type.value.hasPrefix("text/"))
            || type.value == "message/rfc822"
        let body = entity.decodedBody
        if !isAttachment, type.value == "text/plain" || type.value.isEmpty, textBody == nil {
            textBody = Self.string(body, charset: type.parameters["charset"])
        } else if !isAttachment, type.value == "text/html", htmlBody == nil {
            htmlBody = Self.string(body, charset: type.parameters["charset"])
        } else if !body.isEmpty {
            let ext = type.value == "message/rfc822" ? "eml" : (type.value.split(separator: "/").last.map(String.init) ?? "bin")
            attachments.append(Attachment(
                fileName: name.map(Self.decodeWords) ?? "Attachment.\(ext)",
                mimeType: type.value.isEmpty ? "application/octet-stream" : type.value,
                data: body,
                contentID: entity.header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")),
                isInline: disposition?.value == "inline"))
        }
    }

    /// One part: headers, then a body.
    struct Entity {
        var headers: [(name: String, value: String)] = []
        var body: ArraySlice<UInt8>

        init?(_ bytes: ArraySlice<UInt8>) { self.init(Array(bytes)) }

        init?(_ bytes: [UInt8]) {
            // Headers end at the first empty line.
            var index = 0
            var lines: [String] = []
            var lineStart = 0
            var bodyStart = bytes.count
            while index < bytes.count {
                if bytes[index] == 0x0A {
                    var end = index
                    if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
                    if end == lineStart {
                        bodyStart = index + 1
                        break
                    }
                    lines.append(String(decoding: bytes[lineStart..<end], as: UTF8.self))
                    lineStart = index + 1
                }
                index += 1
            }
            if index >= bytes.count, lineStart < bytes.count {
                lines.append(String(decoding: bytes[lineStart...], as: UTF8.self))
            }
            for line in lines {
                if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                    headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                } else if let colon = line.firstIndex(of: ":") {
                    headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
            }
            body = bytes[min(bodyStart, bytes.count)...]
        }

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var contentType: (value: String, parameters: [String: String]) {
            header("Content-Type").map(MIMEMessage.parameters) ?? ("", [:])
        }

        /// The body, its transfer encoding undone.
        var decodedBody: Data {
            switch header("Content-Transfer-Encoding")?.lowercased().trimmingCharacters(in: .whitespaces) {
            case "base64":
                return Data(base64Encoded: String(decoding: body, as: UTF8.self), options: .ignoreUnknownCharacters) ?? Data()
            case "quoted-printable":
                return MIMEMessage.quotedPrintable(body, underscoresAreSpaces: false)
            default:
                return Data(body)
            }
        }

        /// The parts of a multipart body, between its boundary lines.
        func parts(boundary: String) -> [Entity] {
            let marker = Array(("--" + boundary).utf8)
            let bytes = Array(body)
            var starts: [(lineStart: Int, after: Int, isLast: Bool)] = []
            var index = 0
            while index + marker.count <= bytes.count {
                let atLineStart = index == 0 || bytes[index - 1] == 0x0A
                if atLineStart, bytes[index] == 0x2D, Array(bytes[index..<(index + marker.count)]) == marker {
                    let afterMarker = index + marker.count
                    let isLast = afterMarker + 1 < bytes.count && bytes[afterMarker] == 0x2D && bytes[afterMarker + 1] == 0x2D
                    var lineEnd = afterMarker
                    while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
                    starts.append((index, min(lineEnd + 1, bytes.count), isLast))
                    index = lineEnd
                    if isLast { break }
                }
                index += 1
            }
            var parts: [Entity] = []
            for (number, start) in starts.enumerated() where !start.isLast && number + 1 < starts.count {
                var end = starts[number + 1].lineStart
                // The line break before a boundary belongs to it.
                if end > start.after, bytes[end - 1] == 0x0A { end -= 1 }
                if end > start.after, bytes[end - 1] == 0x0D { end -= 1 }
                if let part = Entity(Array(bytes[start.after..<max(start.after, end)])) { parts.append(part) }
            }
            return parts
        }
    }

    // MARK: - Decoding

    /// `text/plain; charset="utf-8"; format=flowed` -> ("text/plain", [charset: utf-8, format: flowed])
    static func parameters(_ header: String) -> (value: String, parameters: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        for character in header {
            if character == "\"" { quoted.toggle() }
            if character == ";", !quoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        let value = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var text = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
            // RFC 2231: filename*=utf-8''na%C3%AFve.pdf
            if key.hasSuffix("*") {
                key.removeLast()
                if let quote = text.range(of: "''") { text = String(text[quote.upperBound...]) }
                text = text.removingPercentEncoding ?? text
            }
            parameters[key] = text
        }
        return (value, parameters)
    }

    static func quotedPrintable<Bytes: Collection>(_ bytes: Bytes, underscoresAreSpaces: Bool) -> Data where Bytes.Element == UInt8 {
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        while index < input.count {
            let byte = input[index]
            if byte == 0x3D {  // =
                // A soft line break.
                if index + 1 < input.count, input[index + 1] == 0x0A { index += 2; continue }
                if index + 2 < input.count, input[index + 1] == 0x0D, input[index + 2] == 0x0A { index += 3; continue }
                if index + 2 < input.count, let high = hex(input[index + 1]), let low = hex(input[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            output.append(underscoresAreSpaces && byte == 0x5F ? 0x20 : byte)
            index += 1
        }
        return Data(output)
    }

    /// Text in a named character set, falling back to UTF-8 and then Latin-1.
    static func string(_ data: Data, charset: String?) -> String {
        let encodings: [String: String.Encoding] = [
            "utf-8": .utf8, "utf8": .utf8, "us-ascii": .ascii, "ascii": .ascii,
            "iso-8859-1": .isoLatin1, "latin1": .isoLatin1, "iso-8859-15": .isoLatin1,
            "windows-1252": .windowsCP1252, "cp1252": .windowsCP1252,
            "iso-8859-2": .isoLatin2, "windows-1250": .windowsCP1250, "windows-1251": .windowsCP1251,
            "utf-16": .utf16, "macintosh": .macOSRoman, "shift_jis": .shiftJIS, "euc-jp": .japaneseEUC,
            "iso-2022-jp": .iso2022JP,
        ]
        if let name = charset?.lowercased(), let encoding = encodings[name], let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#)

    /// RFC 2047: `=?utf-8?Q?Caf=C3=A9?=` -> Café. Space between two encoded words goes.
    public static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let string = text as NSString
        var result = ""
        var cursor = 0
        var lastWasEncoded = false
        for match in encodedWord.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let between = string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(lastWasEncoded && between.trimmingCharacters(in: .whitespaces).isEmpty) { result += between }
            let charset = string.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init)
            let payload = string.substring(with: match.range(at: 3))
            let data: Data?
            if string.substring(with: match.range(at: 2)).uppercased() == "B" {
                data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
            } else {
                data = quotedPrintable(Array(payload.utf8), underscoresAreSpaces: true)
            }
            result += data.map { Self.string($0, charset: charset) } ?? string.substring(with: match.range)
            cursor = match.range.location + match.range.length
            lastWasEncoded = true
        }
        result += string.substring(from: cursor)
        return result
    }

    /// `"Doe, Jane" <jane@example.com>, bob@example.org`
    static func addresses(_ header: String) -> [Address] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var angle = false
        for character in header {
            switch character {
            case "\"": quoted.toggle()
            case "<": angle = true
            case ">": angle = false
            default: break
            }
            if character == ",", !quoted, !angle {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces.compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let email = String(trimmed[trimmed.index(after: open)..<close])
                let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
                return Address(name: name, email: email)
            }
            return Address(name: "", email: trimmed)
        }
    }
}

/// An .mbox file: messages one after another, each starting with a line
/// beginning "From ".
public enum Mbox {
    public static func messages(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let from = Array("From ".utf8)
        func isFromLine(_ index: Int) -> Bool {
            index + from.count <= bytes.count && (index == 0 || bytes[index - 1] == 0x0A)
                && Array(bytes[index..<(index + from.count)]) == from
        }
        var starts: [Int] = []
        var index = 0
        while index < bytes.count {
            if isFromLine(index) { starts.append(index) }
            // On to the next line.
            while index < bytes.count, bytes[index] != 0x0A { index += 1 }
            index += 1
        }
        return starts.enumerated().compactMap { number, start in
            var bodyStart = start
            while bodyStart < bytes.count, bytes[bodyStart] != 0x0A { bodyStart += 1 }
            bodyStart += 1
            let end = number + 1 < starts.count ? starts[number + 1] : bytes.count
            guard bodyStart < end else { return nil }
            return unescape(Array(bytes[bodyStart..<end]))
        }
    }

    /// `>From ` at the start of a line was written for `From ` in the message.
    private static func unescape(_ bytes: [UInt8]) -> Data {
        let escaped = Array(">From ".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let atLineStart = index == 0 || bytes[index - 1] == 0x0A
            if atLineStart, bytes[index] == 0x3E {
                // Only one > comes off: ">>From " was ">From ".
                var probe = index
                while probe < bytes.count, bytes[probe] == 0x3E { probe += 1 }
                if probe + 5 <= bytes.count, Array(bytes[(probe - 1)..<(probe + 5)]) == escaped {
                    index += 1
                    continue
                }
            }
            output.append(bytes[index])
            index += 1
        }
        return Data(output)
    }
}
