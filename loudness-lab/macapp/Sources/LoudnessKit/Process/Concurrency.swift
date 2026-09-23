import Foundation

/// How many tracks to work on at once.
///
/// Audio is not like compiling. Each track in flight holds its whole
/// decoded self in memory -- a quarter of a gigabyte for six minutes of
/// stereo as doubles -- and the stages hold several copies of it at once.
/// One task per core on a sixteen-gigabyte machine would spend longer
/// swapping than filtering, which is not a speed-up however many cores are
/// busy.
///
/// So the width is the smaller of what the machine can compute and what it
/// can hold. This used to be decided twice, differently, in two files: the
/// analyser capped at eight regardless of memory and the processor guessed
/// from memory alone.
public enum Concurrency {

    /// Measuring: the decoded track, its mid/side split, the filtered
    /// copies K-weighting makes, and the frame matrix the spectrum builds.
    ///
    /// An eight-minute mix is 340 MB decoded as doubles before any stage
    /// copies it, and several do. A gigabyte and a half is the honest
    /// figure, not the 800 MB guessed here first.
    public static let measuringBytesPerTrack = 1_500_000_000

    /// Processing: the original, the de-clipped version, the processed one
    /// and, in compare mode, two level-matched renders -- all alive
    /// together.
    public static let processingBytesPerTrack = 2_000_000_000

    /// Half the cores, bounded further by memory.
    ///
    /// Half, not all, and the Python arrived at the same answer first:
    ///
    ///   "Each worker holds a whole decoded track in memory -- a 12-minute
    ///    extended mix is about 280 MB at 48 kHz stereo float32 -- so
    ///    saturating the CPU count costs more in RAM than it buys in
    ///    throughput."
    ///
    /// It is worse here than there, because this side works in Double where
    /// the Python works in float32: the same track costs twice as much to
    /// hold. Running one task per core is how you get a machine that sounds
    /// busy, swaps, and finishes later than it would have at half the
    /// width.
    ///
    /// The memory budget is half of physical, so the rest of the system --
    /// including whatever is playing the results back -- keeps working.
    public static func width(holdingPerTrack bytes: Int) -> Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        let budget = Int(ProcessInfo.processInfo.physicalMemory / 2)
        let byMemory = max(1, budget / max(bytes, 1))
        return max(1, min(cores, byMemory))
    }

    public static func forMeasuring() -> Int {
        width(holdingPerTrack: measuringBytesPerTrack)
    }

    public static func forProcessing() -> Int {
        width(holdingPerTrack: processingBytesPerTrack)
    }
}
