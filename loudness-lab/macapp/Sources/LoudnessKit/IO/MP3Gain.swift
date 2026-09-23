import Foundation

/// Lossless MP3 gain: rewrite `global_gain` instead of re-encoding.
///
/// A port of `loudnesslab/mp3gain.py`. Every MPEG-1/2 Layer III granule
/// carries an 8-bit `global_gain`, and the decoder scales that granule by
/// 2^((global_gain - 210) / 4). Subtracting 1 from every one of them
/// attenuates the file by exactly 1.505 dB without the audio data being
/// touched at all: no decode, no re-encode, no generation loss, and exactly
/// reversible by adding the step back.
///
/// The cost is quantisation -- level moves only in 1.5 dB steps. For a
/// library needing a couple of dB to sit level, that is a far better trade
/// than a second lossy generation.
///
/// Two guarantees, because the alternative is silently damaging someone's
/// records:
///
/// - **The ID3 region is never read or written.** Serato keeps cue points,
///   beatgrids and waveform overviews in GEOB frames there. Only bytes
///   inside audio frames are modified, so those survive byte-for-byte.
/// - **A step applies to every granule or to none.** Clamping individual
///   granules at the ends of the 0-255 range would change the relative level
///   of one part of a track against another, which is exactly the dynamics
///   change this project exists to avoid.
public enum MP3Gain {

    /// 20*log10(2)/4. Spelled as the Python spells it so the two agree to the
    /// last bit rather than to within a rounding of it.
    public static let dbPerStep = 20.0 * 0.3010299956639812 / 4.0

    public static let gainMin = 0, gainMax = 255

    /// Granules below this `global_gain` are inaudible and left alone.
    ///
    /// A decoder reconstructs a line as |is|^(4/3) * 2^((global_gain-210)/4).
    /// The largest |is| the format carries is 8206, so |is|^(4/3) <= 2^17.3;
    /// summing 576 lines coherently -- which real audio never does -- bounds
    /// a granule at 2^26.5 times that scale factor. At global_gain 24 the
    /// scale factor is 2^-46.5, so even that impossible worst case lands
    /// around -120 dBFS, below sixteen-bit dither.
    ///
    /// Encoders emit such granules in fade-ins, run-outs and dithered
    /// lead-ins, and one sitting at global_gain 0 would otherwise pin a whole
    /// track: attenuating would drive it below the field's range, and this
    /// refuses to move some granules but not others.
    ///
    /// Excluding on the threshold alone would not be reversible -- a granule
    /// moved down past the floor would be classified as excluded on the way
    /// back and never restored. Holding the step so that cannot happen was
    /// the first attempt, but then a single granule sitting ON the floor pins
    /// the file just as effectively as one at zero. Instead `apply` reports
    /// the granules a shift pushes across, and the caller records them so an
    /// undo moves exactly the set that was moved.
    public static let audibleGainFloor = 24

    static let bitratesV1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160,
                             192, 224, 256, 320, 0]
    static let bitratesV2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112,
                             128, 144, 160, 0]
    static let sampleRates: [Int: [Int]] = [
        3: [44100, 48000, 32000],   // MPEG-1
        2: [22050, 24000, 16000],   // MPEG-2
        0: [11025, 12000, 8000],    // MPEG-2.5
    ]

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public struct Frame: Equatable, Sendable {
        public let offset: Int        // byte offset of the header in the file
        public let length: Int        // total frame length in bytes
        public let sideInfoAt: Int    // byte offset of the side information
        public let gainBits: [Int]    // absolute bit offsets of each global_gain
        public let hasCRC: Bool
        public let isInfoFrame: Bool  // Xing/Info/VBRI, decodes to silence
    }

    struct Header {
        let length, sideInfoSize, granules, channels: Int
        let blockBits, headerBits: Int
        let hasCRC: Bool
        let sampleRate, bitrate: Int
        let mono: Bool
    }

    // MARK: - Bits

    /// `count` bits starting at an arbitrary bit offset, most significant
    /// first.
    static func bits(_ data: [UInt8], at bitOffset: Int, count: Int) -> Int {
        var value = 0
        for index in 0..<count {
            let position = bitOffset + index
            let byte = position >> 3
            guard byte < data.count else { return value << (count - index) }
            value = (value << 1) | Int((data[byte] >> (7 - UInt8(position & 7))) & 1)
        }
        return value
    }

    static func byte(_ data: [UInt8], at bitOffset: Int) -> Int {
        let index = bitOffset >> 3, shift = bitOffset & 7
        guard index < data.count else { return 0 }
        if shift == 0 { return Int(data[index]) }
        guard index + 1 < data.count else { return Int(data[index]) << shift & 0xFF }
        let window = (Int(data[index]) << 8) | Int(data[index + 1])
        return (window >> (8 - shift)) & 0xFF
    }

    static func setByte(_ data: inout [UInt8], at bitOffset: Int, to value: Int) {
        let index = bitOffset >> 3, shift = bitOffset & 7
        guard index < data.count else { return }
        if shift == 0 { data[index] = UInt8(value); return }
        guard index + 1 < data.count else { return }
        var window = (Int(data[index]) << 8) | Int(data[index + 1])
        let mask = 0xFF << (8 - shift)
        window = (window & ~mask) | (value << (8 - shift))
        data[index] = UInt8((window >> 8) & 0xFF)
        data[index + 1] = UInt8(window & 0xFF)
    }

    // MARK: - Frames

    /// Byte offset of the first thing after an ID3v2 tag.
    public static func skipID3v2(_ data: [UInt8]) -> Int {
        guard data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33
        else { return 0 }
        var size = 0
        for index in 6..<10 { size = (size << 7) | Int(data[index] & 0x7F) }
        var offset = 10 + size
        if data[5] & 0x10 != 0 { offset += 10 }   // footer present
        return min(offset, data.count)
    }

    static func parseHeader(_ data: [UInt8], at offset: Int) -> Header? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b0 = data[offset], b1 = data[offset + 1]
        let b2 = data[offset + 2], b3 = data[offset + 3]
        guard b0 == 0xFF, (b1 & 0xE0) == 0xE0 else { return nil }
        let versionBits = Int((b1 >> 3) & 0x03)
        guard versionBits != 1 else { return nil }            // reserved
        guard (b1 >> 1) & 0x03 == 0x01 else { return nil }    // layer must be III
        let hasCRC = (b1 & 0x01) == 0

        let bitrateIndex = Int((b2 >> 4) & 0x0F)
        let sampleIndex = Int((b2 >> 2) & 0x03)
        guard bitrateIndex != 0, bitrateIndex != 15, sampleIndex != 3 else { return nil }
        let padding = Int((b2 >> 1) & 0x01)
        let mono = Int((b3 >> 6) & 0x03) == 3
        let isV1 = versionBits == 3

        let bitrate = (isV1 ? bitratesV1 : bitratesV2)[bitrateIndex] * 1000
        guard let rates = sampleRates[versionBits] else { return nil }
        let sampleRate = rates[sampleIndex]

        let length: Int, sideInfoSize: Int, granules: Int, blockBits: Int, headerBits: Int
        if isV1 {
            length = (144 * bitrate) / sampleRate + padding
            sideInfoSize = mono ? 17 : 32
            granules = 2; blockBits = 59
            headerBits = 9 + (mono ? 5 : 3) + (mono ? 4 : 8)
        } else {
            length = (72 * bitrate) / sampleRate + padding
            sideInfoSize = mono ? 9 : 17
            granules = 1; blockBits = 63
            headerBits = 8 + (mono ? 1 : 2)
        }
        return Header(length: length, sideInfoSize: sideInfoSize, granules: granules,
                      channels: mono ? 1 : 2, blockBits: blockBits,
                      headerBits: headerBits, hasCRC: hasCRC,
                      sampleRate: sampleRate, bitrate: bitrate, mono: mono)
    }

    static func frame(_ data: [UInt8], at offset: Int, header: Header) -> Frame {
        let sideInfoAt = offset + 4 + (header.hasCRC ? 2 : 0)
        let baseBit = sideInfoAt * 8 + header.headerBits
        // global_gain sits 21 bits into each granule's side-info block.
        let gainBits = (0..<(header.granules * header.channels)).map {
            baseBit + $0 * header.blockBits + 21
        }
        let start = offset + 4
        let end = min(data.count, start + header.sideInfoSize + 8)
        let payload = start < end ? Array(data[start..<end]) : []
        let isInfo = ["Xing", "Info", "VBRI"].contains { contains(payload, Array($0.utf8)) }
        return Frame(offset: offset, length: header.length, sideInfoAt: sideInfoAt,
                     gainBits: gainBits, hasCRC: header.hasCRC, isInfoFrame: isInfo)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// Every Layer III audio frame, in order.
    ///
    /// A candidate is accepted only when a second valid header follows it at
    /// the computed length, so ID3 text and album art cannot masquerade as
    /// audio.
    public static func parseFrames(_ data: [UInt8]) -> [Frame] {
        var frames: [Frame] = []
        var offset = skipID3v2(data)
        let limit = data.count
        while offset + 4 <= limit {
            guard let header = parseHeader(data, at: offset) else { offset += 1; continue }
            let end = offset + header.length
            if end > limit { break }
            if parseHeader(data, at: end) == nil, end + 4 <= limit {
                offset += 1          // not really a frame; keep scanning
                continue
            }
            frames.append(frame(data, at: offset, header: header))
            offset = end
        }
        return frames
    }

    /// False when a granule carries no spectral data at all.
    ///
    /// `part2_3_length` is the first 12 bits of the granule's side-info
    /// block, and `global_gain` sits 21 bits in. A zero-length granule has
    /// nothing to scale, so the decoder outputs silence whatever its
    /// global_gain says.
    ///
    /// The test is on `part2_3_length` rather than on how small global_gain
    /// is, because it does not change when gains shift. A threshold on
    /// global_gain would move granules in and out of the excluded set between
    /// applying a step and reversing it, and the reversal would stop being
    /// byte-exact.
    public static func granuleHasData(_ data: [UInt8], gainBit: Int) -> Bool {
        bits(data, at: gainBit - 21, count: 12) != 0
    }

    /// Bit offsets of every `global_gain` we are willing to move.
    public static func gainBits(_ data: [UInt8], frames: [Frame]) -> [Int] {
        frames.filter { !$0.isInfoFrame }.flatMap(\.gainBits).filter {
            granuleHasData(data, gainBit: $0) && byte(data, at: $0) >= audibleGainFloor
        }
    }

    public static func readGains(_ data: [UInt8], frames: [Frame]) -> [Int] {
        gainBits(data, frames: frames).map { byte(data, at: $0) }
    }

    /// (most we may subtract, most we may add) without clamping any granule.
    /// The only hard limit is the 8-bit field; granules that cross the
    /// audible floor on the way down are recorded, not held against the file.
    public static func headroom(_ gains: [Int]) -> (down: Int, up: Int) {
        guard let low = gains.min(), let high = gains.max() else { return (0, 0) }
        return (low - gainMin, gainMax - high)
    }

    /// Python's `round` is half-to-even, and this has to agree with it or a
    /// track sitting exactly half a step from the target moves in Python and
    /// not here.
    public static func steps(forDB db: Double) -> Int {
        Int((db / dbPerStep).rounded(.toNearestOrEven))
    }

    // MARK: - CRC

    /// MPEG audio frame CRC: x^16 + x^15 + x^2 + 1, seeded 0xFFFF.
    public static func crc16(_ payload: [UInt8]) -> Int {
        var crc = 0xFFFF
        for byte in payload {
            crc ^= Int(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x8005) & 0xFFFF
                                          : (crc << 1) & 0xFFFF
            }
        }
        return crc
    }

    /// Covers the last two header bytes plus the side information -- which is
    /// exactly what gets modified, so a protected frame needs its CRC
    /// recomputed or a checking decoder drops it.
    static func frameCRC(_ data: [UInt8], frame: Frame, sideInfoSize: Int) -> Int {
        var covered = Array(data[(frame.offset + 2)..<(frame.offset + 4)])
        let end = min(data.count, frame.sideInfoAt + sideInfoSize)
        covered += Array(data[frame.sideInfoAt..<end])
        return crc16(covered)
    }

    // MARK: - Planning

    public struct Plan: Sendable {
        public let requestedDB: Double
        public let steps: Int              // steps actually applicable
        public let appliedDB: Double
        public let granules: Int           // granules carrying data
        public let skippedGranules: Int    // empty granules, left alone
        public let protectedFrames: Int    // frames whose CRC must be redone
        public let clamped: Bool           // asked for more than the file had
        public let crossingGranules: Int   // granules this step pushes below the floor
        public let lowestGain: Int         // the gain that limits attenuation
        public let lowestCount: Int
        public let headroomDownDB: Double
    }

    /// The uniform step this file can take toward `targetDB`.
    ///
    /// `maxSteps` is a hard ceiling, used to keep true peak under a limit. It
    /// matters because rounding to the nearest 1.5 dB step can round UP: a
    /// gain capped at +0.9 dB would otherwise become +1.505 and overshoot the
    /// very ceiling that capped it. Callers pass a floored step count, and
    /// this never exceeds it.
    public static func plan(_ data: [UInt8], targetDB: Double,
                            maxSteps: Int? = nil) throws -> Plan {
        let frames = parseFrames(data)
        guard !frames.isEmpty else { throw Failure("no MPEG Layer III frames found") }
        let gains = readGains(data, frames: frames)
        guard !gains.isEmpty else {
            throw Failure("no granule carries audible content -- every one is "
                          + "empty or below global_gain \(audibleGainFloor). "
                          + "Is this file silent?")
        }

        var wanted = steps(forDB: targetDB)
        if let maxSteps { wanted = min(wanted, maxSteps) }
        let room = headroom(gains)
        let allowed = max(-room.down, min(room.up, wanted))
        let lowest = gains.min() ?? 0
        let crossing = allowed < 0
            ? gains.filter { $0 + allowed < audibleGainFloor && $0 >= audibleGainFloor }.count
            : 0
        let total = frames.filter { !$0.isInfoFrame }.reduce(0) { $0 + $1.gainBits.count }

        return Plan(requestedDB: targetDB, steps: allowed,
                    appliedDB: Double(allowed) * dbPerStep,
                    granules: gains.count, skippedGranules: total - gains.count,
                    protectedFrames: frames.filter(\.hasCRC).count,
                    clamped: allowed != wanted, crossingGranules: crossing,
                    lowestGain: lowest, lowestCount: gains.filter { $0 == lowest }.count,
                    headroomDownDB: Double(-room.down) * dbPerStep)
    }

    // MARK: - Applying

    /// Shift `global_gain` by `steps`, and report which granules crossed the
    /// floor.
    ///
    /// Only bytes inside audio frames change. The ID3 region, album art and
    /// any Serato GEOB frames are copied through untouched.
    ///
    /// `alsoMove` names bit offsets to move even though they now read as
    /// inaudible. An undo passes the offsets recorded on the way down, so the
    /// set moved back is exactly the set that was moved.
    public static func apply(_ data: [UInt8], steps: Int,
                             alsoMove: [Int] = []) throws -> (data: [UInt8], crossed: [Int]) {
        guard steps != 0 else { return (data, []) }
        var out = data
        let frames = parseFrames(out)
        let movable = Set(gainBits(out, frames: frames)).union(alsoMove)
        var crossed: [Int] = []

        for frame in frames where !frame.isInfoFrame {
            var touched = false
            for bit in frame.gainBits where movable.contains(bit) {
                let value = byte(out, at: bit) + steps
                guard value >= gainMin, value <= gainMax else {
                    throw Failure("global_gain \(value) out of range at bit \(bit); "
                                  + "plan() should have prevented this")
                }
                setByte(&out, at: bit, to: value)
                if value < audibleGainFloor { crossed.append(bit) }
                touched = true
            }
            if touched, frame.hasCRC, let header = parseHeader(out, at: frame.offset) {
                let recomputed = frameCRC(out, frame: frame,
                                          sideInfoSize: header.sideInfoSize)
                out[frame.offset + 4] = UInt8((recomputed >> 8) & 0xFF)
                out[frame.offset + 5] = UInt8(recomputed & 0xFF)
            }
        }
        return (out, crossed)
    }

    public static func apply(_ data: [UInt8], steps: Int) throws -> [UInt8] {
        try apply(data, steps: steps, alsoMove: []).data
    }
}
