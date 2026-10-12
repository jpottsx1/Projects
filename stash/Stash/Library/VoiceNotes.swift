import AVFoundation
import Foundation
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// Voice notes, and the words in any recording: what's said is turned
/// into a transcript on the device, searchable, and shown in time with
/// the recording as it plays.
extension Library {
    /// Recordings longer than this aren't transcribed by themselves (a
    /// film, an album); *Transcribe* does it when asked.
    static let longestAutomaticTranscription: TimeInterval = 60 * 60

    /// A finished recording, as a voice note.
    @discardableResult
    func addRecording(_ url: URL, besides note: Item? = nil, transcribing: Bool = true) -> Item? {
        let title = "Voice Note " + Date.now.formatted(date: .abbreviated, time: .shortened)
        let item = Item(kind: .document, title: title)
        do {
            item.storedFilePath = try files.importFile(at: url, for: item.uuid)
        } catch {
            importError = error.localizedDescription
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        item.contentTypeIdentifier = UTType.mpeg4Audio.identifier
        item.fileData = syncableContents(of: item)
        insert(item, select: note == nil)
        // Made here, like a note: nothing to file.
        item.inInbox = false
        if let note {
            item.category = note.category
            link(note, to: item)
        }
        save()
        Task {
            await fillContentHash(of: item)
            if transcribing { await transcribe(item) }
        }
        return item
    }

    /// Imported recordings are transcribed unless they're long, or sit in an
    /// indexed folder (which may be someone's music library).
    func shouldTranscribe(_ item: Item, at url: URL) async -> Bool {
        guard item.transcriptData == nil, item.indexedFolder == nil else { return false }
        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return duration > 0 && duration <= Self.longestAutomaticTranscription
    }

    func transcribe(_ item: Item) async {
        guard let url = localFile(for: item), transcribing.insert(item.uuid).inserted else { return }
        transcriptionErrors[item.uuid] = nil
        defer { transcribing.remove(item.uuid) }
        do {
            let transcript = try await Transcriber.transcribe(url)
            guard isAlive(item) else { return }
            item.transcriptData = transcript.json
            item.extractedText = transcript.text()
            reindex(item)
            save()
        } catch {
            transcriptionErrors[item.uuid] = error.localizedDescription
        }
    }

    func transcript(of item: Item) -> Transcript? {
        item.transcriptData.flatMap(Transcript.init(json:))
    }
}
