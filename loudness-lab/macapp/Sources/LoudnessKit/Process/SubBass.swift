import Foundation

/// Kick-synchronised sub-bass, and attack shaping. A port of
/// `loudnesslab/subbass.py`.
///
/// This is NOT a dbx-style frequency divider. A divider flip-flops on zero
/// crossings, which needs a near-monophonic source; in a dense mix the
/// 70-140 Hz band holds the kick, the bassline and the bottom of everything
/// else at once, the tracking fails, and an octave below the wrong partial is
/// a wrong bass note. In dance and pop material most of the missing 32-63 Hz
/// energy is kick, so this detects the kick and lays a short decaying sine
/// under it. Nothing is pitch-tracked, so nothing can mistrack.
///
/// Unlike the gain path this is lossy and irreversible.
public enum SubBass {

    public static let subLowHz = 31.5, subHighHz = 63.0
    public static let kickLowHz = 30.0, kickHighHz = 100.0
    public static let punchLowHz = 2000.0, punchHighHz = 6000.0
    public static let defaultFreqHz = 45.0
    public static let defaultDecayS = 0.12
    public static let defaultPunchDecayMS = 8.0
    public static let punchRampS = 0.001
    public static let minKickSpacingS = 0.12   // 500 BPM; beyond that, not a kick
    public static let attackS = 0.005          // ramp in, or the burst clicks
    public static let onsetRatio = 1.5
    public static let backtrackS = 0.045
    public static let backtrackFraction = 0.25
    public static let minLowActivityDB = 20.0

    public struct Report: Sendable {
        public var kicks = 0
        public var kicksPerMinute = 0.0
        public var requestedDB = 0.0
        public var appliedDB = 0.0
        public var polarityFlipped = false
        public var safetyTrimDB = 0.0
        public var punchDB = 0.0
        public var sustainTrimDB = 0.0
        public var bandLevelChangeDB = 0.0
        public var note: String?

        public init() {}
    }

    // MARK: - Bands

    static func mono(_ x: [[Double]]) -> [Double] {
        guard let first = x.first else { return [] }
        return (0..<first.count).map { i in
            x.reduce(0.0) { $0 + $1[i] } / Double(x.count)
        }
    }

    static func meanSquare(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        return x.reduce(0) { $0 + $1 * $1 } / Double(x.count)
    }

    /// Exact gain that lifts a band by `amountDB`.
    ///
    /// Band power of (track + g*sub) is Et + 2gC + g²Es, so the gain is the
    /// positive root of a quadratic and not the square root of a power ratio
    /// an incoherent estimate would give. That is not academic: the burst is
    /// deliberately phase-aligned with the kick, so the cross term is large,
    /// and assuming independence missed the target by 1.5 dB one way on one
    /// fixture and 0.8 dB the other way on another.
    public static func gainForIncrease(track: [Double], sub: [Double],
                                       amountDB: Double) -> Double {
        let energyTrack = meanSquare(track)
        let energySub = meanSquare(sub)
        guard energySub > 0 else { return 0 }
        let cross = zip(track, sub).reduce(0) { $0 + $1.0 * $1.1 } / Double(track.count)
        let wanted = energyTrack * (pow(10, amountDB / 10) - 1)
        let discriminant = cross * cross + energySub * wanted
        guard discriminant >= 0 else { return 0 }
        return max(0, (-cross + discriminant.squareRoot()) / energySub)
    }

    /// Zero-phase envelope. filtfilt, not filt: a causal envelope lags the
    /// attack by 20-25 ms, and a sub burst that late against a 45 Hz cycle of
    /// 22 ms flams and partly cancels what it was meant to reinforce.
    static func envelope(_ signal: [Double], filter: SOS) -> [Double] {
        filter.filtfilt(signal.map(abs))
    }

    // MARK: - Kicks

    /// Sample offsets and relative strengths of kick onsets.
    ///
    /// The discriminator is attack SHARPNESS, not level: a fast envelope
    /// rising well above a slow one. A bass note that merely changes pitch
    /// does not do that, which is what a plain rising-edge detector kept
    /// mistaking for a kick -- 0.52 recall and 0.30 precision against this
    /// one's 0.9 to 1.0, on synthetic tracks with known kick positions.
    public static func detectKicks(_ x: [[Double]], rate: Double)
    -> (offsets: [Int], strengths: [Double]) {
        let band = FilterBank.kickBand.filtfilt(mono(x))
        let fast = envelope(band, filter: FilterBank.envelope60)
        let slow = envelope(band, filter: FilterBank.envelope3)
        guard fast.contains(where: { $0 > 0 }) else { return ([], []) }

        // A ratio explodes wherever the track is near silent, so only places
        // with real energy in the band are considered at all.
        let floor = (BS1770.percentile(fast, 90) ?? 0) * 1e-3 + 1e-12
        let gate = 0.15 * (BS1770.percentile(fast, 95) ?? 0)
        let onset = (0..<fast.count).map { i in
            fast[i] > gate ? fast[i] / (slow[i] + floor) : 0
        }
        let found = Peaks.find(onset, height: onsetRatio,
                               distance: max(1, Int(minKickSpacingS * rate)))
        guard !found.isEmpty else { return ([], []) }

        let offsets = backtrack(found, fast: fast, rate: rate)
        let strengths = offsets.map { fast[$0] }
        let loudest = strengths.max() ?? 0
        return (offsets, loudest > 0 ? strengths.map { $0 / loudest } : strengths)
    }

    /// Move each onset from the peak of the ratio back to the attack's start.
    /// The ratio peaks once the envelope has already risen, so placing the
    /// burst there leaves it consistently late; walking back to where the
    /// envelope was still a quarter of its peak lands on the attack itself.
    static func backtrack(_ peaks: [Int], fast: [Double], rate: Double) -> [Int] {
        let span = Int(backtrackS * rate)
        return peaks.map { peak in
            let low = max(0, peak - span)
            let target = fast[peak] * backtrackFraction
            var found = peak
            for i in stride(from: peak, through: low, by: -1) where fast[i] <= target {
                found = i
                break
            }
            return found
        }
    }

    // MARK: - Synthesis

    /// One decaying sine, ramped in so the onset does not click.
    static func burst(rate: Double, freq: Double, decayS: Double) -> [Double] {
        let length = Int(decayS * 4 * rate)
        var out = (0..<length).map { index -> Double in
            let t = Double(index) / rate
            return sin(2 * .pi * freq * t) * exp(-t / decayS)
        }
        let ramp = Int(attackS * rate)
        if ramp > 1 {
            for i in 0..<min(ramp, out.count) {
                out[i] *= 0.5 - 0.5 * cos(.pi * Double(i) / Double(ramp))
            }
        }
        return out
    }

    static func layBursts(count: Int, rate: Double, kicks: [Int],
                          strengths: [Double], freq: Double,
                          decayS: Double) -> [Double] {
        var sub = [Double](repeating: 0, count: count)
        let shape = burst(rate: rate, freq: freq, decayS: decayS)
        for (offset, strength) in zip(kicks, strengths) {
            let end = min(count, offset + shape.count)
            guard end > offset else { continue }
            for i in offset..<end { sub[i] += shape[i - offset] * strength }
        }
        // Keep it in the sub octave: nothing inaudible below, nothing muddy
        // above. Causal here, deliberately -- this is a signal being built,
        // not a band being taken out of one and put back.
        return FilterBank.subCeiling.filter(FilterBank.subFloor.filter(sub))
    }

    // MARK: - Content tests

    /// How much the sub octave swings over the track, in dB.
    ///
    /// Measured on the band's own ENVELOPE at a rhythm timescale, not on
    /// per-frame band levels. The frame version answers a different question
    /// and gets this one wrong: a 0.68 s window averages over several kicks,
    /// so a relentless groove -- the most musical low end there is -- reads
    /// as barely moving. A wall-to-wall funk record scored 10.9 dB that way
    /// and a static rumble 6.2, far too close to tell apart; on the envelope
    /// they are 43.7 and 11.3.
    public static func lowBandActivity(_ x: [[Double]], rate: Double) -> Double {
        let band = FilterBank.subBand.filtfilt(mono(x))
        let level = FilterBank.envelope20.filtfilt(band.map(abs)).filter { $0 > 0 }
        guard Double(level.count) >= rate else { return .nan }
        guard let quiet = BS1770.percentile(level, 10),
              let loud = BS1770.percentile(level, 90),
              quiet > 0, loud > 0 else { return .nan }
        return 20 * log10(loud / quiet)
    }

    /// How far the band leaps above its usual level at each kick, in dB.
    ///
    /// The metric for attack work; global crest factor is not. A band-limited
    /// change lasting eight milliseconds does not move a track's overall
    /// peak-to-loudness ratio at all, which is why crest read +0.02 dB while
    /// the attacks were plainly being emphasised. Crest staying put is in
    /// fact the desirable outcome: the track's dynamic character is untouched
    /// and only the micro-detail moved.
    public static func attackContrast(_ x: [[Double]], rate: Double, kicks: [Int],
                                      windowS: Double = 0.015) -> Double {
        guard !kicks.isEmpty else { return .nan }
        let band = FilterBank.punchBand.filtfilt(mono(x))
        let level = FilterBank.envelope200.filtfilt(band.map(abs))
        guard let baseline = BS1770.percentile(level, 50), baseline > 0 else { return .nan }
        let span = Int(windowS * rate)
        let peaks = kicks.compactMap { k -> Double? in
            guard k + 8 < level.count else { return nil }
            return level[k..<min(k + span, level.count)].max()
        }
        guard let median = BS1770.percentile(peaks, 50) else { return .nan }
        return 20 * log10(median / baseline)
    }

    // MARK: - Attack shaping

    /// Emphasise the attack of each kick WITHOUT adding energy to the band.
    ///
    /// A transient shaper, not an expander, and the difference is the whole
    /// point. An expander keys on absolute level over tens of milliseconds
    /// and so changes how loud passages sit against quiet ones -- it raises
    /// loudness range, which is exactly what makes tracks disagree with each
    /// other. This keys on where the kicks are, acts over a few milliseconds,
    /// and leaves loudness range alone.
    ///
    /// The band is renormalised afterwards to the energy it started with, so
    /// what changes is the distribution of that energy in time and not how
    /// much of it there is. Without that step this would be a treble boost
    /// wearing a transient shaper's name, and the long-term spectrum would
    /// show it.
    public static func shapeAttacks(_ x: [[Double]], rate: Double, kicks: [Int],
                                    strengths: [Double], boostDB: Double,
                                    decayMS: Double = defaultPunchDecayMS,
                                    report: inout Report) -> [[Double]] {
        guard boostDB > 0, !kicks.isEmpty else { report.punchDB = 0; return x }
        report.punchDB = boostDB

        // Zero-phase, so that (x - band) is a true complement and recombining
        // cannot leave a phase-shifted residue behind.
        let band = x.map { FilterBank.punchBand.filtfilt($0) }
        let rest = (0..<x.count).map { c in
            (0..<x[c].count).map { x[c][$0] - band[c][$0] }
        }

        let decay = decayMS / 1000
        let length = max(2, Int(decay * 5 * rate))
        var shape = (0..<length).map { index -> Double in
            (pow(10, boostDB / 20) - 1) * exp(-Double(index) / rate / decay)
        }
        let ramp = Int(punchRampS * rate)
        if ramp > 1 {
            for i in 0..<min(ramp, shape.count) {
                shape[i] *= 0.5 - 0.5 * cos(.pi * Double(i) / Double(ramp))
            }
        }

        var gain = [Double](repeating: 1, count: x[0].count)
        for (offset, strength) in zip(kicks, strengths) {
            let end = min(gain.count, offset + length)
            guard end > offset else { continue }
            for i in offset..<end { gain[i] += shape[i - offset] * strength }
        }

        var shaped = band.map { channel in
            (0..<channel.count).map { channel[$0] * gain[$0] }
        }
        let before = band.reduce(0.0) { $0 + meanSquare($1) } / Double(band.count)
        let after = shaped.reduce(0.0) { $0 + meanSquare($1) } / Double(shaped.count)
        if before > 0, after > 0 {
            let trim = (before / after).squareRoot()
            shaped = shaped.map { $0.map { $0 * trim } }
            report.sustainTrimDB = 20 * log10(trim)
            let settled = shaped.reduce(0.0) { $0 + meanSquare($1) } / Double(shaped.count)
            report.bandLevelChangeDB = 10 * log10(settled / before)
        }
        return (0..<x.count).map { c in
            (0..<x[c].count).map { rest[c][$0] + shaped[c][$0] }
        }
    }

    // MARK: - The stage

    /// Add `amountDB` of energy to the 31.5-63 Hz octave, under the kicks.
    /// Returns the new audio and a report of what was actually done, because
    /// the point of a prototype is to be checked rather than believed.
    public static func enhance(_ x: [[Double]], rate: Double, amountDB: Double,
                               freq: Double = defaultFreqHz,
                               decayS: Double = defaultDecayS,
                               punchDB: Double = 0,
                               punchDecayMS: Double = defaultPunchDecayMS)
    -> (audio: [[Double]], report: Report) {
        var report = Report()
        report.requestedDB = amountDB
        guard amountDB > 0 || punchDB > 0 else {
            report.note = "no spectral change asked for"
            return (x, report)
        }

        let (kicks, strengths) = detectKicks(x, rate: rate)
        report.kicks = kicks.count
        let seconds = Double(x[0].count) / rate / 60
        report.kicksPerMinute = seconds > 0 ? Double(kicks.count) / seconds : 0
        guard kicks.count >= 8 else {
            report.note = "too few kick onsets to work from"
            return (x, report)
        }

        if amountDB <= 0, punchDB > 0 {
            let out = shapeAttacks(x, rate: rate, kicks: kicks, strengths: strengths,
                                   boostDB: punchDB, decayMS: punchDecayMS,
                                   report: &report)
            return (out, report)
        }

        var sub = layBursts(count: x[0].count, rate: rate, kicks: kicks,
                            strengths: strengths, freq: freq, decayS: decayS)
        guard meanSquare(sub) > 0 else {
            report.note = "synthesis produced nothing"
            return (x, report)
        }

        let trackBand = FilterBank.subBand.filter(mono(x))
        var subBand = FilterBank.subBand.filter(sub)
        guard meanSquare(subBand) > 0 else {
            report.note = "synthesis landed outside the target band"
            return (x, report)
        }

        // Reinforce rather than fight what is already under the kick.
        let cross = zip(trackBand, subBand).reduce(0) { $0 + $1.0 * $1.1 }
        if cross < 0 {
            sub = sub.map(-); subBand = subBand.map(-)
            report.polarityFlipped = true
        }

        let gain = gainForIncrease(track: trackBand, sub: subBand, amountDB: amountDB)
        let existing = meanSquare(trackBand)
        var out = x.map { channel in
            (0..<channel.count).map { channel[$0] + sub[$0] * gain }
        }

        // Measured BEFORE any trim. A trim scales everything equally, so it
        // moves level without touching spectral balance -- and spectral
        // balance is the entire point. Reporting the two together made a
        // correct +5 dB lift read as +3.4 on a track that happened to need
        // 1.6 dB of headroom.
        let after = meanSquare(FilterBank.subBand.filter(mono(out)))
        if existing > 0, after > 0 { report.appliedDB = 10 * log10(after / existing) }

        // Punch after the sub: the sub is part of the kick now, and shaping
        // the attack of the finished kick is what the ear is judging.
        if punchDB > 0 {
            out = shapeAttacks(out, rate: rate, kicks: kicks, strengths: strengths,
                               boostDB: punchDB, decayMS: punchDecayMS, report: &report)
        }

        let peak = out.flatMap { $0 }.map(abs).max() ?? 0
        if peak > 0.99 {
            let trim = 0.99 / peak
            out = out.map { $0.map { $0 * trim } }
            report.safetyTrimDB = 20 * log10(trim)
        }
        return (out, report)
    }
}
