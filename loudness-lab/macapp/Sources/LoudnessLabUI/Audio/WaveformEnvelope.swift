import Foundation
import LoudnessKit

/// A track's shape, downsampled to a fixed number of columns and split
/// into three bands, so a waveform can be colored the way a DJ mixer's own
/// overview already is -- warm for the bottom end, cool for the top,
/// because that is the axis a track actually gets processed on.
///
/// Deliberately not in `LoudnessKit`. Nothing here is a measurement --
/// the crossover points are round numbers picked to look right, not fitted
/// to a corpus, and there is no golden vector holding them to the Python.
/// That is fine for a picture and would not be fine for a number.
struct WaveformEnvelope: Sendable {
    /// Overall amplitude per column, already 0...1 within this envelope.
    let peak: [Float]
    let bass: [Float]
    let mid: [Float]
    let treble: [Float]

    static let empty = WaveformEnvelope(peak: [], bass: [], mid: [], treble: [])

    var isEmpty: Bool { peak.isEmpty }
}

enum WaveformAnalyzer {
    /// Fine enough that a kick drum still reads as a transient, coarse
    /// enough that a six-minute track is a few hundred columns rather than
    /// several million points a `Canvas` would happily choke on.
    static let columns = 600

    /// Where the bottom band ends and the top band begins. Round numbers,
    /// not measured -- see the type's own doc comment for why that is
    /// fine here and would not be elsewhere in this project.
    static let bassCeilingHz = 200.0
    static let trebleFloorHz = 2000.0

    /// Runs the decode and the filtering, which for a six-minute track is
    /// worth keeping off the main actor -- the same reason `Processor`
    /// does its work off it.
    static func analyze(_ url: URL) async throws -> WaveformEnvelope {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try analyzeSync(url)
        }.value
    }

    private static func analyzeSync(_ url: URL) throws -> WaveformEnvelope {
        let (audio, _) = try AudioDecoder.decode(url)
        let rate = AudioDecoder.targetRate
        let n = audio[0].count
        guard n > 0 else { return .empty }

        // Summed to mono for the picture. A DJ overview waveform has never
        // been about which channel carries what; that is what the L/R
        // meters are for.
        var mono = [Double](repeating: 0, count: n)
        for i in 0..<n { mono[i] = (audio[0][i] + audio[1][i]) * 0.5 }

        let bassLow = onePoleLowPass(mono, cutoffHz: bassCeilingHz, rate: rate)
        let midLow = onePoleLowPass(mono, cutoffHz: trebleFloorHz, rate: rate)

        let columns = min(Self.columns, n)
        let perColumn = max(1, n / columns)

        var peak = [Float](), bass = [Float](), mid = [Float](), treble = [Float]()
        peak.reserveCapacity(columns); bass.reserveCapacity(columns)
        mid.reserveCapacity(columns); treble.reserveCapacity(columns)

        var start = 0
        while start < n {
            let end = min(start + perColumn, n)
            var peakAcc = 0.0, bassAcc = 0.0, midAcc = 0.0, trebleAcc = 0.0
            for i in start..<end {
                peakAcc = max(peakAcc, abs(mono[i]))
                bassAcc += bassLow[i] * bassLow[i]
                let midValue = midLow[i] - bassLow[i]
                midAcc += midValue * midValue
                let trebleValue = mono[i] - midLow[i]
                trebleAcc += trebleValue * trebleValue
            }
            let count = Double(end - start)
            peak.append(Float(peakAcc))
            bass.append(Float((bassAcc / count).squareRoot()))
            mid.append(Float((midAcc / count).squareRoot()))
            treble.append(Float((trebleAcc / count).squareRoot()))
            start = end
        }
        return WaveformEnvelope(peak: peak, bass: bass, mid: mid, treble: treble)
    }

    /// A single-pole exponential filter, not a Butterworth -- the whole
    /// point is that this is cheap, one pass, no design table, and good
    /// enough for a coloring effect rather than a measurement. Two of
    /// these, at different corners, are what split the signal into three
    /// bands: below the first is bass, between the two is mid, above the
    /// second is treble.
    private static func onePoleLowPass(_ x: [Double], cutoffHz: Double,
                                       rate: Double) -> [Double] {
        let alpha = 1 - exp(-2 * Double.pi * cutoffHz / rate)
        var y = [Double](repeating: 0, count: x.count)
        var previous = 0.0
        for i in 0..<x.count {
            previous += alpha * (x[i] - previous)
            y[i] = previous
        }
        return y
    }
}
