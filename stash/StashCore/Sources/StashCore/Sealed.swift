import Foundation

/// What a locked item keeps encrypted, all together in one sealed box:
/// its text, and everything else that says what's in it. Its title and
/// tags stay readable, so it can be found and listed. Files are sealed
/// separately (see `SealedFormat`).
public struct SealedContents: Codable, Equatable {
    public struct HighlightText: Codable, Equatable {
        public var id: UUID
        public var text: String
        public var note: String

        public init(id: UUID, text: String, note: String) {
            self.id = id
            self.text = text
            self.note = note
        }
    }

    public var body: String
    public var extractedText: String
    public var summary: String
    /// A link's clean article (an `Article` as JSON).
    public var article: Data?
    /// A recording's transcript (a `Transcript` as JSON).
    public var transcript: Data?
    public var highlights: [HighlightText]

    public init(body: String = "", extractedText: String = "", summary: String = "", article: Data? = nil,
                transcript: Data? = nil, highlights: [HighlightText] = []) {
        self.body = body
        self.extractedText = extractedText
        self.summary = summary
        self.article = article
        self.transcript = transcript
        self.highlights = highlights
    }

    public var json: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init?(json: Data) {
        guard let value = try? JSONDecoder().decode(Self.self, from: json) else { return nil }
        self = value
    }
}

/// How encrypted data is laid out, so it's never taken for the real thing:
/// a marker, then the cipher's output (AES-GCM's nonce, ciphertext and tag).
public enum SealedFormat {
    public static let marker = Array("STASHSEAL1".utf8)

    public static func isSealed(_ data: Data) -> Bool {
        data.count > marker.count && Array(data.prefix(marker.count)) == marker
    }

    public static func wrap(_ cipher: Data) -> Data {
        Data(marker) + cipher
    }

    /// The cipher's output, or nil when the data isn't sealed.
    public static func unwrap(_ data: Data) -> Data? {
        isSealed(data) ? Data(data.dropFirst(marker.count)) : nil
    }
}
