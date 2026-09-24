import AVFoundation
import Foundation

/// Decoding, at last without ffmpeg.
///
/// The Python shells out to ffmpeg, so there is no reference implementation
/// to be held to here the way there is everywhere else in this port -- only
/// a different decoder doing the same job. That difference is real and worth
/// stating plainly: Apple's MP3 decoder and ffmpeg's do not agree sample for
/// sample, and they may trim encoder priming by different amounts, so the
/// same file measured by the app and by the Python can differ slightly. The
/// test target measures how much rather than assuming it is nothing.
///
/// Everything comes out at 48 kHz stereo, because the K-weighting
/// coefficients in BS.1770-4 are published at that rate and deriving them
/// for another is an error this project does not need.
public enum AudioDecoder {

    public static let targetRate = 48000.0

    public static let audioSuffixes: Set<String> = [
        "mp3", "flac", "aiff", "aif", "aifc", "wav", "m4a", "aac",
        "ogg", "opus", "wv", "wma", "caf", "alac",
    ]

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Per-channel samples at 48 kHz, always two channels.
    ///
    /// A mono source is upmixed to dual mono deliberately rather than left
    /// as one channel: a mono record played in a club comes out of both
    /// stacks, so that is the signal worth measuring. What it really was is
    /// recorded separately.
    public static func decode(_ url: URL) throws -> (audio: [[Double]], sourceChannels: Int) {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let channels = Int(source.channelCount)
        guard channels > 0 else { throw Failure("no audio channels in \(url.lastPathComponent)") }

        // Mono is converted as mono and duplicated afterwards. Asking the
        // converter for two channels from one leaves the upmix to its own
        // rules, which are not documented to be a plain duplication and have
        // been known to apply a -3 dB spread; doing it here means the signal
        // is the one intended rather than the one inferred.
        let outputChannels: AVAudioChannelCount = channels == 1 ? 1 : 2
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: targetRate,
                                         channels: outputChannels,
                                         interleaved: false) else {
            throw Failure("could not describe the output format")
        }

        let decoded = source.sampleRate == targetRate
            && source.channelCount == outputChannels
            ? try readWhole(file)
            : try convert(file, to: target)

        guard let first = decoded.first, !first.isEmpty else {
            throw Failure("\(url.lastPathComponent) decoded to empty audio")
        }
        return (decoded.count == 1 ? [first, first] : decoded, channels)
    }

    static func readWhole(_ file: AVAudioFile) throws -> [[Double]] {
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return [] }
        try file.read(into: buffer)
        return samples(from: buffer)
    }

    static func convert(_ file: AVAudioFile, to target: AVAudioFormat) throws -> [[Double]] {
        let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw Failure("no conversion from \(source) to \(target)")
        }
        // Sample-rate conversion is not one-in one-out, so the converter is
        // pulled until it says it is finished rather than driven a fixed
        // number of times.
        let chunk: AVAudioFrameCount = 1 << 16
        var out: [[Double]] = Array(repeating: [], count: Int(target.channelCount))
        var reachedEnd = false

        while true {
            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(chunk) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: target,
                                                frameCapacity: capacity) else {
                throw Failure("could not allocate an output buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if reachedEnd { outStatus.pointee = .endOfStream; return nil }
                guard let input = AVAudioPCMBuffer(pcmFormat: source,
                                                   frameCapacity: chunk) else {
                    outStatus.pointee = .endOfStream; return nil
                }
                do { try file.read(into: input, frameCount: chunk) } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }

            let block = samples(from: output)
            for channel in block.indices { out[channel].append(contentsOf: block[channel]) }

            if status == .endOfStream || status == .error { break }
            if output.frameLength == 0 && reachedEnd { break }
        }
        return out
    }

    static func samples(from buffer: AVAudioPCMBuffer) -> [[Double]] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else {
            return Array(repeating: [], count: Int(buffer.format.channelCount))
        }
        return (0..<Int(buffer.format.channelCount)).map { channel in
            let pointer = data[channel]
            return (0..<frames).map { Double(pointer[$0]) }
        }
    }
}
