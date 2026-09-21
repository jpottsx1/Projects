import AVFoundation
import Foundation

/// Writing the processed audio out.
///
/// FLAC rather than another MP3, deliberately: this stage has already spent
/// one decode, and a second lossy encode gives away more than the sub is
/// worth. From here the file is lossless.
public enum AudioWriter {

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
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
