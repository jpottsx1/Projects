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

    /// Measuring: the decoded track, its mid/side split, and the frames the
    /// spectrum builds from it.
    public static let measuringBytesPerTrack = 800_000_000

    /// Processing: the original, the de-clipped version, the processed one
    /// and, in compare mode, two level-matched renders -- all alive
    /// together.
    public static let processingBytesPerTrack = 1_500_000_000

    /// Cores, bounded by half the machine's memory. Half, so that the rest
    /// of the system -- including whatever is playing the results back --
    /// keeps working while a library is being ground through.
    public static func width(holdingPerTrack bytes: Int) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
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
