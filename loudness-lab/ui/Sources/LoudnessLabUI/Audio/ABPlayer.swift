import AVFoundation
import Foundation

/// Plays every version of a track at once and lets you listen to one of them.
///
/// This is the whole point of the app, so it is worth being explicit about
/// what it does NOT do. It does not stop one file and start another at the
/// same timestamp: seeking takes time, decoders prime, and the moment of the
/// switch -- the moment you are trying to judge -- is exactly where the
/// artefacts of switching would land. Instead every version is decoded up
/// front, scheduled on its own player node, and all of them are started at
/// one shared sample time on one engine clock. They then run in lockstep
/// forever, because they are being pulled by the same render callback.
///
/// Switching is therefore not a transport operation at all. It is a gain
/// change on a mixer: the one you are listening to goes to unity, the others
/// go to silence. Nothing seeks, nothing re-primes, and the bar you were in
/// keeps playing. A short ramp is applied because an instantaneous gain
/// change on a non-zero sample is a step discontinuity, which is a click.
@MainActor
final class ABPlayer: ObservableObject {

    struct Source {
        let id: String
        let label: String
        let url: URL
        /// dB to apply so every version monitors at the same loudness. Without
        /// it the comparison measures which is louder, and louder wins.
        let matchGainDB: Float
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var selected: String?
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var loaded: [Source] = []
    @Published var matchLoudness = true { didSet { applyGains(ramp: 0.05) } }
    @Published private(set) var problem: String?

    /// Long enough that a step is inaudible, short enough that you are never
    /// listening to a blend of the two while judging one.
    private let switchRamp: TimeInterval = 0.012

    private let engine = AVAudioEngine()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var gains: [String: AVAudioMixerNode] = [:]
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var sources: [String: Source] = [:]
    private var startSampleTime: AVAudioFramePosition?
    private var ticker: Timer?
    private var ramps: [ObjectIdentifier: Timer] = [:]

    // MARK: - Loading

    /// Decodes every version and wires it up. Throws rather than half-loading:
    /// a comparison missing one side is worse than no comparison.
    func load(_ incoming: [Source]) throws {
        stop()
        teardown()
        problem = nil
        guard let first = incoming.first else { return }

        // One common format for every node, taken from the first file. Mixing
        // formats between nodes is legal but makes the engine resample, and a
        // resampler in one path and not the other is a difference you would
        // hear and wrongly attribute to the processing.
        let reference = try AVAudioFile(forReading: first.url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: reference.processingFormat.sampleRate,
                                   channels: reference.processingFormat.channelCount,
                                   interleaved: false)!

        var lengths: [AVAudioFramePosition] = []
        for source in incoming {
            let file = try AVAudioFile(forReading: source.url)
            guard file.processingFormat.sampleRate == format.sampleRate,
                  file.processingFormat.channelCount == format.channelCount else {
                throw Failure.mismatch(source.label)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(file.length)) else {
                throw Failure.allocation(source.label)
            }
            try file.read(into: buffer)
            buffer.frameLength = AVAudioFrameCount(file.length)
            lengths.append(file.length)

            let player = AVAudioPlayerNode()
            let gain = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(gain)
            engine.connect(player, to: gain, format: format)
            engine.connect(gain, to: engine.mainMixerNode, format: format)
            gain.outputVolume = 0

            players[source.id] = player
            gains[source.id] = gain
            buffers[source.id] = buffer
            sources[source.id] = source
        }

        // Sample-locking only means anything if the files line up in the first
        // place. Everything the CLI writes for one track comes out of a single
        // decode, so it does; anything else is the user's own pairing and they
        // need to be told rather than left wondering why it doubles.
        if Set(lengths).count > 1, let shortest = lengths.min(), let longest = lengths.max() {
            let drift = Double(longest - shortest) / format.sampleRate
            problem = String(format: "These versions differ in length by %.3f s, "
                             + "so they will not stay lined up. Compare files "
                             + "the tool rendered together.", drift)
        }

        duration = Double(lengths.max() ?? 0) / format.sampleRate
        loaded = incoming
        selected = first.id
        engine.prepare()
    }

    // MARK: - Transport

    func play(from offset: TimeInterval = 0) {
        guard !loaded.isEmpty else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            problem = "Could not start the audio engine: \(error.localizedDescription)"
            return
        }

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let startFrame = AVAudioFramePosition(max(0, offset) * format.sampleRate)

        // One start time for everything. Far enough ahead that every node has
        // been scheduled before the clock reaches it, or the first to be
        // scheduled would begin a render cycle early and the rest would chase.
        let lead = AVAudioFramePosition(0.2 * format.sampleRate)
        let now = engine.outputNode.lastRenderTime?.sampleTime ?? 0
        let when = AVAudioTime(sampleTime: now + lead, atRate: format.sampleRate)

        for source in loaded {
            guard let player = players[source.id],
                  let buffer = buffers[source.id] else { continue }
            player.stop()
            let toPlay = startFrame > 0 ? Self.slice(buffer, from: startFrame) : buffer
            guard let toPlay else { continue }
            player.scheduleBuffer(toPlay, at: when, options: [])
        }
        applyGains(ramp: 0)
        for source in loaded { players[source.id]?.play(at: when) }

        startSampleTime = when.sampleTime - startFrame
        isPlaying = true
        startTicking()
    }

    func pause() {
        guard isPlaying else { return }
        let held = position
        for player in players.values { player.stop() }
        isPlaying = false
        stopTicking()
        position = held
    }

    func stop() {
        for player in players.values { player.stop() }
        isPlaying = false
        stopTicking()
        position = 0
        startSampleTime = nil
    }

    func seek(to offset: TimeInterval) {
        let wasPlaying = isPlaying
        for player in players.values { player.stop() }
        position = min(max(0, offset), duration)
        if wasPlaying { play(from: position) } else { stopTicking() }
    }

    // MARK: - Switching

    /// The switch. No seek, no restart: the other versions have been playing
    /// underneath in silence the whole time, and this only decides which one
    /// reaches the output.
    func select(_ id: String) {
        guard sources[id] != nil, id != selected else { return }
        selected = id
        applyGains(ramp: switchRamp)
    }

    func selectNext() {
        guard let current = selected,
              let index = loaded.firstIndex(where: { $0.id == current }) else { return }
        select(loaded[(index + 1) % loaded.count].id)
    }

    private func applyGains(ramp: TimeInterval) {
        for source in loaded {
            guard let gain = gains[source.id] else { continue }
            let wanted: Float = source.id == selected
                ? (matchLoudness ? pow(10, source.matchGainDB / 20) : 1)
                : 0
            if ramp <= 0 {
                gain.outputVolume = wanted
            } else {
                rampVolume(of: gain, to: wanted, over: ramp)
            }
        }
    }

    /// AVAudioMixerNode has no parameter ramp of its own, so this steps the
    /// value on one timer on the main actor. The step is small enough and the
    /// span short enough that what you hear is a crossfade, not a staircase.
    ///
    /// One timer for the whole switch, not one per node and not a queue of
    /// blocks per step: a switch interrupted by another switch has to be
    /// abandoned cleanly, and scheduled work that has already been handed to
    /// a queue cannot be.
    private func rampVolume(of node: AVAudioMixerNode, to target: Float,
                            over span: TimeInterval) {
        let start = node.outputVolume
        guard abs(target - start) > 0.0001 else { node.outputVolume = target; return }
        let steps = 24
        var step = 0
        let timer = Timer.scheduledTimer(withTimeInterval: span / Double(steps),
                                         repeats: true) { timer in
            Task { @MainActor in
                step += 1
                let progress = Float(step) / Float(steps)
                node.outputVolume = start + (target - start) * progress
                if step >= steps {
                    node.outputVolume = target
                    timer.invalidate()
                }
            }
        }
        ramps[ObjectIdentifier(node)]?.invalidate()
        ramps[ObjectIdentifier(node)] = timer
    }

    // MARK: - Position

    private func startTicking() {
        stopTicking()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isPlaying, let origin = startSampleTime,
              let rendered = engine.outputNode.lastRenderTime?.sampleTime else { return }
        let rate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        position = max(0, Double(rendered - origin) / rate)
        if position >= duration { stop() }
    }

    private func teardown() {
        for node in players.values { engine.detach(node) }
        for node in gains.values { engine.detach(node) }
        for timer in ramps.values { timer.invalidate() }
        ramps.removeAll()
        players.removeAll(); gains.removeAll()
        buffers.removeAll(); sources.removeAll()
        loaded = []; selected = nil; duration = 0; position = 0
    }

    /// Everything after `from`, as a new buffer.
    ///
    /// Playing from an offset could be done with scheduleSegment, but that
    /// takes a file and would put a disk read back in the path we spent the
    /// decode to remove. Copying out of the buffer we already hold keeps the
    /// restart instant, which matters because seeking restarts every version
    /// at once and any one of them stalling would break the lock.
    static func slice(_ buffer: AVAudioPCMBuffer,
                      from start: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let total = AVAudioFramePosition(buffer.frameLength)
        guard start > 0, start < total else { return start <= 0 ? buffer : nil }
        let remaining = AVAudioFrameCount(total - start)
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                         frameCapacity: remaining),
              let source = buffer.floatChannelData,
              let destination = out.floatChannelData else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + Int(start),
                                        count: Int(remaining))
        }
        out.frameLength = remaining
        return out
    }

    enum Failure: LocalizedError {
        case mismatch(String), allocation(String)
        var errorDescription: String? {
            switch self {
            case .mismatch(let name):
                return "\(name) has a different sample rate or channel count "
                     + "from the first file, so they cannot be compared in step."
            case .allocation(let name):
                return "Could not make room in memory for \(name)."
            }
        }
    }
}
