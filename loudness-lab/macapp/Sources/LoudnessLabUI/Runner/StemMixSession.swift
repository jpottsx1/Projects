import Foundation

/// One track's stem mix: prepared by the command, played here, and either
/// committed through an ordinary processing run or thrown away.
///
/// Preparing splits the track (Demucs, about forty seconds a track on this
/// Mac's GPU) and writes the layers into a scratch folder under
/// ~/Music/LoudnessLab/stem-mix. Every fader after that is a gain on a
/// buffer already playing -- `ABPlayer.setMix` -- so nothing is rendered
/// while a slider moves. Commit writes the choice beside the layers and
/// runs the processing command for this one track with `--stem-mix`; the
/// command builds the track from the same layers at the same gains, then
/// levels and writes it as any run does. Cancel, or a finished Commit,
/// removes the scratch folder. Nothing reaches the output folder before
/// Commit.
@MainActor
final class StemMixSession: ObservableObject {

    enum Phase: Equatable {
        case idle, preparing, ready, committing, committed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bundle: StemMix.Bundle?
    /// Why the last Commit wrote nothing, said in the sheet.
    @Published private(set) var problem: String?
    /// Where Save As put the track; nil after a plain Commit.
    @Published private(set) var savedTo: URL?
    /// What the faders say. Every change is heard at once.
    @Published var choice: StemMix.Choice? {
        didSet { if choice != oldValue { applyMix() } }
    }
    let player = ABPlayer()
    let path: String

    private var folder: URL?
    private var started: StemMix.Choice?
    private let flag = Engine.CancelFlag()

    init(path: String) { self.path = path }

    /// Where the layers wait while the mix is open.
    nonisolated static var scratch: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/LoudnessLab/stem-mix", isDirectory: true)
    }

    var name: String { bundle?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

    var hasChanged: Bool { choice != nil && choice != started }

    /// Split the track and load its layers. `arguments` is the processing
    /// command for the current settings (`Engine.processArguments`), so the
    /// preview starts where a run would: the same de-clipping, dynamics,
    /// mud and body before the sub, the same sub and air amounts to begin.
    func prepare(arguments: [String], bassSub: Bool) async {
        guard phase != .preparing else { return }
        guard let tool = CLI.locate() else { phase = .failed(CLI.missing); return }
        discardLayers()
        phase = .preparing
        flag.reset()
        let folder = Self.scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let listing = FileManager.default.temporaryDirectory
            .appendingPathComponent("loudnesslab-stemmix-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listing) }
        let refusal = Refusal()
        do {
            try FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
            try path.write(to: listing, atomically: true, encoding: .utf8)
            var command = arguments + ["--select", listing.path, "--stem-preview", folder.path]
            if bassSub && !command.contains("--bass-sub") { command.append("--bass-sub") }
            _ = try await CLI.run(tool, command, isCancelled: { [flag] in flag.isCancelled }) { line in
                guard let event = CLI.Event(line), event.event == "error" else { return }
                refusal.set(event.message ?? "The stem mix could not be prepared.")
            }
            if flag.isCancelled { try? FileManager.default.removeItem(at: folder); phase = .idle; return }
            if let message = refusal.message { throw CLI.Failure(message) }
            self.folder = folder
            let bundle = try StemMix.Bundle.read(folder)
            try player.load(StemMix.layers.compactMap { layer in
                bundle.files[layer].map {
                    ABPlayer.Source(id: layer, label: layer,
                                    url: folder.appendingPathComponent($0), matchGainDB: 0)
                }
            })
            self.bundle = bundle
            let start = StemMix.Choice.start(bundle, folder: folder)
            started = start
            choice = start
            phase = .ready
        } catch {
            try? FileManager.default.removeItem(at: folder)
            self.folder = nil
            phase = .failed(refusal.message ?? error.localizedDescription)
        }
    }

    /// Back to where the mix opened: stems at 0 dB, the sub and air at
    /// what the settings gave this track.
    func reset() { choice = started }

    /// Write the chosen mix as a finished track. `run` is the app's
    /// processing run for this one track with the choice file attached
    /// (`Engine.run(..., stemMix:)`); it returns nil once the track is
    /// written, or why it was not. With `saveAs`, the track goes to that
    /// file instead of the output folder.
    func commit(saveAs: URL? = nil, run: (URL, URL?) async -> String?) async {
        guard phase == .ready, let folder, let choice else { return }
        player.pause()
        phase = .committing
        problem = nil
        savedTo = nil
        do {
            let file = folder.appendingPathComponent("choice.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(choice).write(to: file)
            if let failure = await run(file, saveAs) {
                // Kept: the mix can be tried again, or cancelled.
                problem = failure
                phase = .ready
            } else {
                discardLayers()
                savedTo = saveAs
                phase = .committed
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stop preparing, stop playing, and remove the layers. Nothing was
    /// written anywhere else.
    func cancel() {
        flag.cancel()
        discardLayers()
        phase = .idle
    }

    private func discardLayers() {
        player.unload()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        bundle = nil
        choice = nil
        started = nil
    }

    private func applyMix() {
        guard let bundle, let choice else { return }
        player.setMix(StemMix.gains(bundle, choice).mapValues { Float($0) })
    }

    /// The tool's own sentence when it refuses, read off a worker thread.
    private final class Refusal: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ text: String) { lock.lock(); value = value ?? text; lock.unlock() }
        var message: String? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
