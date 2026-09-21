import AVFoundation
import Foundation

/// Writing the processed audio out.
///
/// FLAC is the default and the honest one: this stage has already spent a
/// decode, and a second lossy encode gives away more than the sub is worth.
/// But a lossless file is four times the size and not every player wants
/// one, so MP3 and AAC are offered for the copies that go into a set.
///
/// Both A and B of a comparison pair always get the SAME format. Writing a
/// lossless original against a lossy processed version would have you
/// listening to the codec and calling it the processing.
public enum AudioWriter {

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public enum Format: String, CaseIterable, Sendable, Codable {
        case flac = "FLAC"
        case mp3 = "MP3 320"
        // 256, not the 320 that was asked for, because 320 is not a thing
        // AAC actually does: ffmpeg's native encoder was measured returning
        // about 200 kbps for a 320 request and 208 for a 256 one -- it
        // clamps, silently, and a control labelled 320 would be describing
        // something that never happens. 256 is also where AAC-LC is
        // generally reckoned transparent, and what Apple ship music at.
        case aac = "AAC 256"

        public var fileExtension: String {
            switch self {
            case .flac: return "flac"
            case .mp3: return "mp3"
            case .aac: return "m4a"     // AAC in the container players expect
            }
        }

        public var isLossless: Bool { self == .flac }

        /// What ffmpeg is asked for. Nothing here for FLAC: that one is
        /// written directly and never goes near an encoder.
        var encoderArguments: [String] {
            switch self {
            case .flac: return []
            case .mp3: return ["-c:a", "libmp3lame", "-b:a", "320k"]
            case .aac:
                // Apple's encoder where the build has it -- macOS ffmpeg
                // usually does, and it is better than the native one at
                // this bitrate. Checked rather than assumed, because it is
                // a build option.
                let encoder = Tools.hasEncoder("aac_at") ? "aac_at" : "aac"
                return ["-c:a", encoder, "-b:a", "256k"]
            }
        }
    }

    /// Write `audio` in `format`.
    ///
    /// `tagsFrom` is the file this came from. Its metadata is copied across,
    /// because a processed track with no artist and no title is one you
    /// cannot find again -- and a library of them is worse than not having
    /// processed anything.
    ///
    /// Serato's cue points are NOT carried. They live in GEOB frames, this
    /// is a new file with new audio, and nothing short of writing those
    /// frames back would keep them. The lossless gain path is the one that
    /// preserves them; this stage never has.
    public static func write(_ audio: [[Double]], to url: URL,
                             format: Format = .flac,
                             rate: Double = AudioDecoder.targetRate,
                             tagsFrom source: URL? = nil) throws {
        guard format != .flac else {
            return try writeFLAC(audio, to: url, rate: rate)
        }
        guard let ffmpeg = Tools.find("ffmpeg") else {
            throw Failure("ffmpeg is needed to write \(format.rawValue) and "
                          + "was not found. Install it with: brew install "
                          + "ffmpeg — or choose FLAC, which needs nothing.")
        }

        // Losslessly first, then encoded once. Going straight from the
        // samples would mean teaching this about raw pipes and byte order
        // for no gain: the intermediate is deleted either way.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("loudnesslab-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try writePCM(audio, to: scratch, rate: rate, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: audio.count,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var arguments = ["-nostdin", "-v", "error", "-y", "-i", scratch.path]
        if let source {
            arguments += ["-i", source.path, "-map", "0:a:0", "-map_metadata", "1"]
        }
        arguments += format.encoderArguments + [url.path]
        try Tools.run(ffmpeg, arguments)
    }

    public static func writeFLAC(_ audio: [[Double]], to url: URL,
                                 rate: Double = AudioDecoder.targetRate) throws {
        guard let first = audio.first, !first.isEmpty else {
            throw Failure("nothing to write")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // FLAC carries integers, so the float buffer is written through a
        // 24-bit setting: enough that the quantisation is far below anything
        // the processing changed, and honest about the format rather than
        // pretending 32-bit float survives the round trip.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: audio.count,
            AVLinearPCMBitDepthKey: 24,
        ]
        try writePCM(audio, to: url, rate: rate, settings: settings)
    }

    /// The common path: samples to a file AVFoundation can write directly.
    static func writePCM(_ audio: [[Double]], to url: URL, rate: Double,
                         settings: [String: Any]) throws {
        guard let first = audio.first, !first.isEmpty else {
            throw Failure("nothing to write")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate,
                                         channels: AVAudioChannelCount(audio.count),
                                         interleaved: false) else {
            throw Failure("could not describe the writing format")
        }

        let chunk = 1 << 16
        var offset = 0
        while offset < first.count {
            let frames = min(chunk, first.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.floatChannelData else {
                throw Failure("could not allocate a writing buffer")
            }
            for channel in audio.indices {
                let source = audio[channel]
                for i in 0..<frames {
                    // Clipped on the way out, because a restored peak can
                    // stand above full scale and an integer format cannot.
                    data[channel][i] = Float(min(max(source[offset + i], -1.0), 1.0))
                }
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            offset += frames
        }
    }
}
