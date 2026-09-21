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
    /// Serato's cue points ARE carried, MP3 to MP3, by copying the
    /// original's whole ID3v2 tag onto the new file. ffmpeg will not do it
    /// -- `-map_metadata` carries text and drops GEOB, measured: two frames
    /// in, none out -- so the tag is spliced on afterwards.
    ///
    /// That is only worth doing because the timing survives. Cue positions
    /// are times, so they land on the right beat only if the new file's
    /// audio starts where the old one's did. Measured on a real Serato
    /// file: decode, encode at 320, decode again, and the result is the
    /// same length with a maximum sample difference of 0.00003 -- the
    /// codec, and no shift at all. LAME writes the delay into its header
    /// and the decoder gives it back.
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

        // MP3 out of MP3 takes the original tag wholesale rather than
        // letting ffmpeg write a new one, so ffmpeg is told to write none.
        let carryWholeTag = format == .mp3 && isMP3(source)
        var arguments = ["-nostdin", "-v", "error", "-y", "-i", scratch.path]
        if carryWholeTag {
            arguments += ["-map_metadata", "-1", "-write_id3v1", "0",
                          "-id3v2_version", "0"]
        } else if let source {
            arguments += ["-i", source.path, "-map", "0:a:0", "-map_metadata", "1"]
        }
        arguments += format.encoderArguments + [url.path]
        try Tools.run(ffmpeg, arguments)
        if carryWholeTag, let source { try carryID3v2(from: source, to: url) }
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

    static func isMP3(_ url: URL?) -> Bool {
        url?.pathExtension.lowercased() == "mp3"
    }

    /// Prepend the original's entire ID3v2 tag to the new file.
    ///
    /// The whole tag, not the GEOB frames alone. Picking frames out means
    /// re-encoding their sizes between ID3 versions, minding the
    /// unsynchronisation flag, and deciding what else is worth keeping --
    /// three chances to get it subtly wrong for no benefit. Copied whole,
    /// everything the original carried arrives intact: cues, beatgrid,
    /// artwork, comments, the lot.
    static func carryID3v2(from source: URL, to url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return }
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 10), head.count == 10 else { return }
        let length = id3v2Length([UInt8](head))
        guard length > 10 else { return }          // no tag, nothing to carry
        try handle.seek(toOffset: 0)
        guard let tag = try handle.read(upToCount: length),
              tag.count == length else { return }
        let encoded = try Data(contentsOf: url)
        // Written whole rather than in place: a half-written file here is a
        // track that will not play.
        try (tag + encoded).write(to: url, options: .atomic)
    }

    /// Bytes from the start of the file to the end of an ID3v2 tag.
    ///
    /// The size is syncsafe -- seven bits per byte, so the length can never
    /// contain a run that looks like a frame sync. Reading it as a plain
    /// integer is the classic way to land in the middle of the audio.
    static func id3v2Length(_ header: [UInt8]) -> Int {
        guard header.count >= 10,
              header[0] == 0x49, header[1] == 0x44, header[2] == 0x33
        else { return 0 }
        let size = (Int(header[6] & 0x7F) << 21) | (Int(header[7] & 0x7F) << 14)
                 | (Int(header[8] & 0x7F) << 7)  |  Int(header[9] & 0x7F)
        // Bit 4 of the flags is a footer, another ten bytes at the end.
        return 10 + size + ((header[5] & 0x10) != 0 ? 10 : 0)
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
