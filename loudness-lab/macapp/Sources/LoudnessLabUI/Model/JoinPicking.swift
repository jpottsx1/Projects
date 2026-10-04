import Foundation
import CoreGraphics

/// The track as three bands over time, as the intro tool draws it: made in
/// Python from the audio the bar lines were found in, so a marker on a bar
/// line sits on the transient it names.
struct JoinEnvelope: Equatable, Sendable {
    /// Columns a second.
    let perSecond: Double
    let seconds: Double
    /// 0...255 each, on one shared scale.
    let bass: [UInt8]
    let mid: [UInt8]
    let treble: [UInt8]

    init(perSecond: Double, seconds: Double, bass: [UInt8], mid: [UInt8], treble: [UInt8]) {
        self.perSecond = perSecond; self.seconds = seconds
        self.bass = bass; self.mid = mid; self.treble = treble
    }

    /// Nil unless the event carries all three bands and a rate.
    init?(event: IntroEvent) {
        guard let perSecond = event.perSecond, perSecond > 0,
              let bass = event.bass, let mid = event.mid, let treble = event.treble,
              !bass.isEmpty, bass.count == mid.count, bass.count == treble.count
        else { return nil }
        func bytes(_ values: [Int]) -> [UInt8] { values.map { UInt8(clamping: $0) } }
        self.init(perSecond: perSecond, seconds: event.seconds ?? Double(bass.count) / perSecond,
                  bass: bytes(bass), mid: bytes(mid), treble: bytes(treble))
    }

    var columns: Int { bass.count }

    /// The largest value in a band over `[start, end)` seconds. A column on
    /// screen can cover many columns here, and a mean would flatten the very
    /// kicks the picture is for.
    func peak(_ band: [UInt8], from start: Double, to end: Double) -> Float {
        guard !band.isEmpty else { return 0 }
        let lo = max(0, min(band.count - 1, Int(start * perSecond)))
        let hi = max(lo, min(band.count - 1, Int((end * perSecond).rounded(.up)) - 1))
        var top: UInt8 = 0
        for i in lo...hi where band[i] > top { top = band[i] }
        return Float(top) / 255
    }
}

/// The arithmetic of choosing a join, apart from any view, so it can be
/// tested without a screen.
///
/// A join is a BAR LINE, never a free position: the new intro is a whole
/// number of bars and the song has to arrive on a downbeat, so a marker that
/// could land between beats would only be a way to make a bad edit.
enum JoinMath {

    /// The bar line nearest `seconds`, as an index into `bars` (every bar
    /// line from the first). Clamped to the bars the song can arrive at: the
    /// last bar line has no bar after it.
    static func nearestBar(to seconds: Double, in bars: [Double]) -> Int {
        let last = max(0, bars.count - 2)
        guard bars.count > 1 else { return 0 }
        // Binary search for the first bar line at or after `seconds`.
        var lo = 0, hi = bars.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if bars[mid] < seconds { lo = mid + 1 } else { hi = mid }
        }
        let after = lo
        let before = max(0, lo - 1)
        let nearest = abs(bars[before] - seconds) <= abs(bars[after] - seconds) ? before : after
        return min(max(0, nearest), last)
    }

    static func clamp(_ bar: Int, in bars: [Double]) -> Int {
        min(max(0, bar), max(0, bars.count - 2))
    }

    static func seconds(ofBar bar: Int, in bars: [Double]) -> Double {
        guard !bars.isEmpty else { return 0 }
        return bars[min(max(0, bar), bars.count - 1)]
    }

    /// The span of time a strip of `width` seconds shows around `center`,
    /// kept inside `0...total` and never narrower than asked unless the
    /// track itself is.
    static func window(center: Double, width: Double, total: Double) -> ClosedRange<Double> {
        let span = min(width, total)
        let lo = min(max(0, center - span / 2), max(0, total - span))
        return lo...(lo + span)
    }

    static func x(for seconds: Double, in window: ClosedRange<Double>, width: CGFloat) -> CGFloat {
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((seconds - window.lowerBound) / span) * width
    }

    static func seconds(forX x: CGFloat, in window: ClosedRange<Double>, width: CGFloat) -> Double {
        guard width > 0 else { return window.lowerBound }
        let span = window.upperBound - window.lowerBound
        return window.lowerBound + Double(x / width) * span
    }

    /// "1:25.6", for reading a time off the picker.
    static func clock(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
