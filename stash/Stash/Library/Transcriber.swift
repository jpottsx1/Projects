import AVFoundation
import Foundation
import Speech
import StashCore

/// Turns speech in a recording into a `Transcript`, on the device: with
/// SpeechAnalyzer on iOS and macOS 26, the older recognizer before that.
enum Transcriber {
    enum Failure: LocalizedError {
        case notAllowed
        case unsupportedLanguage
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notAllowed: "Stash isn’t allowed to recognise speech. You can allow it in Settings › Privacy & Security › Speech Recognition."
            case .unsupportedLanguage: "This device can’t recognise speech in your language."
            case .unreadable: "The recording couldn’t be read."
            }
        }
    }

    /// Speech recognition, asked for the first time it's needed.
    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    static func transcribe(_ url: URL, locale: Locale = .current) async throws -> Transcript {
        // Video: its sound track, as audio.
        var audio = url
        var temporary: URL?
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) {
            audio = try await soundTrack(of: url)
            temporary = audio
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        if #available(iOS 26, macOS 26, *), SpeechTranscriber.isAvailable {
            do {
                return try await analyze(audio, locale: locale)
            } catch {
                // Asked for only if it turns out to be needed.
                guard SFSpeechRecognizer.authorizationStatus() == .notDetermined, await authorize() else { throw error }
                return try await analyze(audio, locale: locale)
            }
        }
        guard await authorize() else { throw Failure.notAllowed }
        return try await recognize(audio, locale: locale)
    }

    @available(iOS 26, macOS 26, *)
    private static func analyze(_ url: URL, locale: Locale) async throws -> Transcript {
        var found = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if found == nil { found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let chosen = found else { throw Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: chosen, preset: .transcription)
        // The language's model is downloaded the first time.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadable }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collecting = Task {
            var segments: [Transcript.Segment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(.init(start: result.range.start.seconds,
                                      end: result.range.end.seconds, text: text))
            }
            return segments
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let segments = try await collecting.value
        return Transcript(segments: segments.sorted { $0.start < $1.start }, locale: chosen.identifier)
    }

    private static func recognize(_ url: URL, locale: Locale) async throws -> Transcript {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw Failure.unsupportedLanguage
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        let identifier = recognizer.locale.identifier
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.duration) }
                    continuation.resume(returning: Transcript(segments: Transcript.phrases(fromWords: words), locale: identifier))
                } else if let error {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// A video's sound, written out as an audio file to read.
    private static func soundTrack(of url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.unreadable
        }
        let output = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try await export.export(to: output, as: .m4a)
        return output
    }
}

/// Records from the microphone into an AAC file, with the level and time
/// for showing while it goes.
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// 0 to 1.
    private(set) var level: Double = 0
    var error: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private(set) var url: URL?

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Stash isn’t allowed to use the microphone. You can allow it in Settings › Privacy & Security › Microphone."
            return
        }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            self.error = error.localizedDescription
            return
        }
        #endif
        let url = URL.temporaryDirectory.appendingPathComponent("Voice Note \(UUID().uuidString.prefix(6)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                error = "Recording couldn’t start."
                return
            }
            self.recorder = recorder
            self.url = url
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // -60 dB and below is silence.
        level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 60) / 60))
        elapsed = recorder.currentTime
    }

    /// Stops, and gives the finished file.
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        return url
    }

    /// Stops and throws the recording away.
    func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
        url = nil
    }
}
