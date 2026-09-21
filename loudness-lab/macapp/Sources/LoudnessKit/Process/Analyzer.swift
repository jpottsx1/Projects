import Foundation

/// Measuring a folder into a database.
///
/// A port of `loudnesslab/analyze.py`. Tracks already measured and unchanged
/// are skipped, because re-running a scan over a real library otherwise
/// costs hours for nothing.
public enum Analyzer {

    public struct Counts: Sendable {
        public var found = 0, analysed = 0, skipped = 0, errors = 0
        /// Seconds spent in each stage, summed across every track.
        ///
        /// Here because guessing at this from the code has now been wrong
        /// twice: first that the fix was more parallelism, then that it was
        /// the width. A number settles it.
        public var decodeSeconds = 0.0
        public var loudnessSeconds = 0.0
        public var spectrumSeconds = 0.0
        public var tagSeconds = 0.0
        public init() {}

        /// One line saying where the time actually went.
        public func timingLine() -> String {
            let total = decodeSeconds + loudnessSeconds + spectrumSeconds + tagSeconds
            guard total > 0, analysed > 0 else { return "" }
            func share(_ value: Double, _ name: String) -> String {
                String(format: "%@ %.1fs (%.0f%%)", name, value, value / total * 100)
            }
            return "  per track \(String(format: "%.1f", total / Double(analysed)))s — "
                + [share(decodeSeconds, "decode"), share(loudnessSeconds, "loudness"),
                   share(spectrumSeconds, "spectrum"), share(tagSeconds, "tags")]
                    .joined(separator: ", ")
        }
    }

    public struct Progress: Sendable {
        public let done: Int, total: Int, name: String, failed: Bool
        /// True while the folders are still being walked and each file
        /// checked against the database. `total` is not known yet, and on a
        /// large library this phase is long enough that saying nothing
        /// during it reads as a hang.
        public var scanning = false
    }

    /// Measure everything under `roots` into `library`.
    ///
    /// Work runs concurrently across files -- measurement is the slow part
    /// and each track is independent -- while the database is written from
    /// one place, because SQLite would rather not be written from several.
    public static func run(roots: [URL], library: Library,
                           jobs: Int = Concurrency.forMeasuring(),
                           isCancelled: @escaping @Sendable () -> Bool = { false },
                           progress: (@Sendable (Progress) -> Void)? = nil) async -> Counts {
        var counts = Counts()
        var pending: [URL] = []

        for root in roots {
            let survey = FileSurvey.survey(root)
            counts.found += survey.audio.count
            var looked = 0
            for url in survey.audio {
                if isCancelled() { return counts }
                looked += 1
                // Every hundredth, because the callback hops to the main
                // actor and doing that per file would cost more than the
                // check it is reporting on.
                if looked % 100 == 0 {
                    progress?(Progress(done: looked, total: survey.audio.count,
                                       name: root.lastPathComponent,
                                       failed: false, scanning: true))
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? Int) ?? 0
                let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
                let nanoseconds = Int(modified.timeIntervalSince1970 * 1_000_000_000)
                let needed = (try? library.needsAnalysis(url, size: size,
                                                         mtimeNanoseconds: nanoseconds)) ?? true
                if needed { pending.append(url) } else { counts.skipped += 1 }
            }
        }

        let total = pending.count
        var done = 0
        var index = 0
        // Bounded by Concurrency, which weighs cores against memory. The
        // flat cap of eight that used to be here ignored how much a track
        // costs to hold, which is the thing that actually limits this.
        let width = max(1, min(jobs, max(1, pending.count)))

        // Bounded rather than unbounded: one task per track would decode a
        // whole library at once and run the machine out of memory long
        // before it ran out of patience. A new one starts as each finishes.
        //
        // Written inline because a nested function cannot capture `group` --
        // the closure holds it as an inout parameter, which Swift will not
        // let an inner function close over.
        await withTaskGroup(of: Library.Analysis.self) { group in
            while index < pending.count, index < width {
                let url = pending[index]
                index += 1
                group.addTask { await analyse(url) }
            }

            for await result in group {
                done += 1
                if result.status == "ok" { counts.analysed += 1 } else { counts.errors += 1 }
                counts.decodeSeconds += result.timings.decode
                counts.loudnessSeconds += result.timings.loudness
                counts.spectrumSeconds += result.timings.spectrum
                counts.tagSeconds += result.timings.tags
                try? library.store(result)
                progress?(Progress(done: done, total: total,
                                   name: result.url.lastPathComponent,
                                   failed: result.status != "ok"))
                // Checked between tracks: a track already decoding runs to
                // the end, but nothing new starts. Stop meaning "stop soon"
                // is the difference between a button that works and one
                // that is merely present.
                if !isCancelled(), index < pending.count {
                    let url = pending[index]
                    index += 1
                    group.addTask { await analyse(url) }
                }
            }
        }
        return counts
    }

    /// One track. Never throws: a broken file is a row with a reason in it,
    /// not a scan that stops halfway through a library.
    public static func analyse(_ url: URL) async -> Library.Analysis {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        let nanoseconds = Int(modified.timeIntervalSince1970 * 1_000_000_000)

        var timings = Library.Analysis.Timings()
        func clock<T>(_ into: inout Double, _ work: () throws -> T) rethrows -> T {
            let started = DispatchTime.now().uptimeNanoseconds
            let value = try work()
            into += Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            return value
        }

        do {
            let (audio, sourceChannels) = try clock(&timings.decode) {
                try AudioDecoder.decode(url)
            }
            // Awaited, not waited on. Blocking a cooperative-pool thread
            // with a semaphore while the Task it is waiting for needs that
            // same pool deadlocks as soon as the machine is busy, which is
            // exactly when a library scan runs.
            let tagsStarted = DispatchTime.now().uptimeNanoseconds
            var tags = (try? await Tags.read(url)) ?? Tags()
            timings.tags = Double(DispatchTime.now().uptimeNanoseconds - tagsStarted) / 1e9
            if tags.sourceChannels == nil { tags.sourceChannels = sourceChannels }

            let loudness = clock(&timings.loudness) { BS1770.measure(audio) }
            let bands = clock(&timings.spectrum) {
                Spectrum.analyse(audio, rate: AudioDecoder.targetRate,
                                 sourceIsMono: sourceChannels == 1)
            }

            return Library.Analysis(
                url: url, sizeBytes: size, mtimeNanoseconds: nanoseconds,
                status: "ok", tags: tags,
                codec: url.pathExtension.lowercased(),
                loudness: loudness, bands: bands, timings: timings)
        } catch {
            return Library.Analysis(url: url, sizeBytes: size,
                                    mtimeNanoseconds: nanoseconds,
                                    status: "error",
                                    error: error.localizedDescription)
        }
    }
}
