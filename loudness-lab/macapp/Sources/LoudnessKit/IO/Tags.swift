import AVFoundation
import Foundation

/// What a file says about itself.
///
/// The year rule is the part with history behind it. A compilation's plain
/// `date` tag is the REISSUE year: "100 Hits - The New Romantics (2011)" is
/// a 2011 release of 1980-84 recordings, and reading that as 2011 filed
/// early-eighties mastering into the modern reference curve and quietly
/// spoiled every era comparison drawn from it. Original-recording tags are
/// therefore checked first and release tags second, and which one answered
/// is recorded, because era grouping is only meaningful when the year says
/// when the record was MADE.
public struct Tags: Sendable {
    public var artist: String?
    public var title: String?
    public var album: String?
    public var genre: String?
    public var year: Int?
    /// True when `year` came from an original-recording tag rather than a
    /// release tag. A library of compilations where this is false throughout
    /// will produce an era table that says nothing.
    public var yearIsOriginal: Bool?
    public var bpm: Double?
    public var musicalKey: String?
    public var durationSeconds: Double?
    public var sourceRate: Int?
    public var sourceChannels: Int?

    public static let originalYearKeys = ["originaldate", "originalyear",
                                          "original_year", "original date",
                                          "tdor", "tory"]
    public static let releaseYearKeys = ["date", "year", "tdrc", "tyer",
                                         "tdrl", "release_date"]

    /// First four-digit 19xx or 20xx in the string, as the Python's regex
    /// finds it -- tags carry "1981-06", "1981/06/01" and worse.
    public static func year(in text: String) -> Int? {
        let digits = Array(text)
        guard digits.count >= 4 else { return nil }
        for start in 0...(digits.count - 4) {
            let slice = digits[start..<(start + 4)]
            guard let value = Int(String(slice)) else { continue }
            if (1900...1999).contains(value) || (2000...2099).contains(value) {
                return value
            }
        }
        return nil
    }

    /// (year, came from an original-recording tag). Keys are matched
    /// lowercased, because the same tag arrives spelled several ways.
    public static func year(from tags: [String: String]) -> (Int?, Bool?) {
        for key in originalYearKeys {
            if let text = tags[key], let found = year(in: text) { return (found, true) }
        }
        for key in releaseYearKeys {
            if let text = tags[key], let found = year(in: text) { return (found, false) }
        }
        return (nil, nil)
    }

    public static func make(from tags: [String: String]) -> Tags {
        var out = Tags()
        out.artist = tags["artist"] ?? tags["album_artist"] ?? tags["albumartist"]
        out.title = tags["title"]
        out.album = tags["album"]
        out.genre = tags["genre"]
        (out.year, out.yearIsOriginal) = year(from: tags)
        out.bpm = (tags["tbpm"] ?? tags["bpm"]).flatMap(Double.init)
        out.musicalKey = tags["initialkey"] ?? tags["tkey"] ?? tags["key"]
        return out
    }

    /// Reads what AVFoundation exposes, in every metadata format the file
    /// carries. ID3, iTunes and QuickTime name the same things differently,
    /// so all of them are flattened into one lowercased dictionary and the
    /// first value for a key wins -- matching how the Python merges ffprobe's
    /// format and stream tags.
    public static func read(_ url: URL) async throws -> Tags {
        let asset = AVURLAsset(url: url)
        var flat: [String: String] = [:]

        func absorb(_ items: [AVMetadataItem]) async {
            for item in items {
                guard let raw = item.commonKey?.rawValue
                        ?? item.key as? String
                        ?? item.identifier?.rawValue.split(separator: "/").last.map(String.init)
                else { continue }
                let key = raw.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{00A9}"))
                guard flat[key] == nil else { continue }
                if let text = try? await item.load(.stringValue), !text.isEmpty {
                    flat[key] = text
                } else if let number = try? await item.load(.numberValue) {
                    flat[key] = number.stringValue
                }
            }
        }

        if let common = try? await asset.load(.commonMetadata) { await absorb(common) }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let items = try? await asset.loadMetadata(for: format) {
                    await absorb(items)
                }
            }
        }

        var out = make(from: flat)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            out.durationSeconds = seconds.isFinite ? seconds : nil
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            out.sourceRate = Int(basic.pointee.mSampleRate)
            out.sourceChannels = Int(basic.pointee.mChannelsPerFrame)
        }
        return out
    }
}
