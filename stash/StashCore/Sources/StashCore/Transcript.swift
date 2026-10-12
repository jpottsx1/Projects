import Foundation

/// What was said in a recording, phrase by phrase, each with when it was
/// said: for reading along as it plays, and jumping to a phrase.
public struct Transcript: Codable, Equatable {
    public struct Segment: Codable, Equatable {
        /// Seconds into the recording.
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var segments: [Segment]
    /// The language it was heard in, as an identifier ("en-GB").
    public var locale: String

    public init(segments: [Segment], locale: String = "") {
        self.segments = segments
        self.locale = locale
    }

    /// All of it, as paragraphs: a pause of `pause` seconds or more starts a new one.
    public func text(pause: Double = 2) -> String {
        var paragraphs: [[String]] = []
        var lastEnd: Double?
        for segment in segments {
            let words = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            if let lastEnd, segment.start - lastEnd < pause, !paragraphs.isEmpty {
                paragraphs[paragraphs.count - 1].append(words)
            } else {
                paragraphs.append([words])
            }
            lastEnd = segment.end
        }
        return paragraphs.map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    /// The segment being said at `time`, or the last one before it, for
    /// following along; nil before the first.
    public func segmentIndex(at time: Double) -> Int? {
        guard let first = segments.first, time >= first.start else { return nil }
        // Segments are in order: the last one that has started.
        var low = 0, high = segments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if segments[middle].start <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Words heard one at a time, with their times, made into phrases: a
    /// new one after a sentence ends, at a pause, or once one grows long.
    public static func phrases(fromWords words: [(text: String, start: Double, duration: Double)],
                               pause: Double = 0.8, maxWords: Int = 24) -> [Segment] {
        var segments: [Segment] = []
        var current: [String] = []
        var start = 0.0, end = 0.0
        func flush() {
            guard !current.isEmpty else { return }
            segments.append(Segment(start: start, end: end, text: current.joined(separator: " ")))
            current = []
        }
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if !current.isEmpty, word.start - end >= pause { flush() }
            if current.isEmpty { start = word.start }
            current.append(text)
            end = word.start + word.duration
            if let last = text.last, ".?!".contains(last) || current.count >= maxWords { flush() }
        }
        flush()
        return segments
    }

    /// "1:05", "1:02:03".
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    public var json: Data? { try? JSONEncoder().encode(self) }

    public init?(json: Data) {
        guard let value = try? JSONDecoder().decode(Self.self, from: json) else { return nil }
        self = value
    }
}
