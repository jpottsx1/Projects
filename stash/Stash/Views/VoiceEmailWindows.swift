import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import StashCore
#if os(macOS)
import AppKit
#endif

// MARK: - Recording

/// Records a voice note: on its own, or into a note, where what was said
/// goes in at the cursor once it's been transcribed.
struct RecordingSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// The note to put the words into; nil for a voice note on its own.
    var note: Item?
    var onTranscript: (String, Item) -> Void = { _, _ in }
    @State private var recorder = VoiceRecorder()
    @State private var isTranscribing = false

    var body: some View {
        VStack(spacing: 20) {
            Text(note == nil ? "New Voice Note" : "Record into Note")
                .font(.headline)
            Text(Transcript.timestamp(recorder.elapsed))
                .font(.system(size: 44, weight: .light, design: .rounded).monospacedDigit())
            ProgressView(value: recorder.level)
                .progressViewStyle(.linear)
                .tint(.red)
                .frame(maxWidth: 240)
                .opacity(recorder.isRecording ? 1 : 0.3)
            if isTranscribing {
                ProgressView("Transcribing…")
            } else if let error = recorder.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
                Button("Cancel", role: .cancel) {
                    recorder.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    if recorder.isRecording { finish() } else { Task { await recorder.start() } }
                } label: {
                    Label(recorder.isRecording ? "Stop" : "Record",
                          systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("recordButton")
            }
            .disabled(isTranscribing)
        }
        .padding(32)
        .sheetSize(minWidth: 340, minHeight: 300)
        .task { await recorder.start() }
        .interactiveDismissDisabled(recorder.isRecording || isTranscribing)
    }

    private func finish() {
        guard let url = recorder.stop(), let item = library.addRecording(url, besides: note, transcribing: note == nil) else {
            dismiss()
            return
        }
        guard note != nil else {
            dismiss()
            return
        }
        isTranscribing = true
        Task {
            await library.transcribe(item)
            let words = library.transcript(of: item)?.text() ?? ""
            onTranscript(words, item)
            dismiss()
        }
    }
}

// MARK: - Playing

/// An audio or video document: the player, and what's said, which follows
/// along as it plays; choosing a phrase plays from there.
struct MediaPlayerView: View {
    @Environment(Library.self) private var library
    let item: Item
    let url: URL
    @State private var player = AVPlayer()
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var rate: Float = 1
    @State private var isScrubbing = false
    @State private var observer: Any?

    private var isVideo: Bool { item.contentType?.conforms(to: .movie) == true }

    var body: some View {
        VStack(spacing: 0) {
            if isVideo {
                VideoPlayer(player: player)
                    .frame(minHeight: 220, idealHeight: 320)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .padding(.vertical, 20)
            }
            controls
                .padding(.horizontal)
                .padding(.vertical, 10)
            Divider()
            transcript
        }
        .onAppear(perform: load)
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                seek(to: time - 15)
            } label: {
                Label("Back 15 Seconds", systemImage: "gobackward.15")
            }
            Button {
                if isPlaying { player.pause() } else { player.playImmediately(atRate: rate) }
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(" ", modifiers: [])
            .accessibilityIdentifier("playButton")
            Button {
                seek(to: time + 15)
            } label: {
                Label("Forward 15 Seconds", systemImage: "goforward.15")
            }
            Text(Transcript.timestamp(time))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(value: $time, in: 0...max(duration, 1)) { editing in
                isScrubbing = editing
                if !editing { seek(to: time) }
            }
            Text(Transcript.timestamp(duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { speed in
                    Button(speed == rate ? "✓ \(speed.formatted())×" : "\(speed.formatted())×") {
                        rate = speed
                        if isPlaying { player.rate = speed }
                    }
                }
            } label: {
                Text("\(rate.formatted())×").monospacedDigit()
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var transcript: some View {
        if let transcript = library.transcript(of: item), !transcript.segments.isEmpty {
            let current = transcript.segmentIndex(at: time)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                            Button {
                                seek(to: segment.start)
                                if !isPlaying {
                                    player.playImmediately(atRate: rate)
                                    isPlaying = true
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(Transcript.timestamp(segment.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .trailing)
                                    Text(segment.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .multilineTextAlignment(.leading)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(index == current ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .accessibilityIdentifier("transcriptSegment")
                        }
                    }
                    .padding()
                }
                .onChange(of: current) {
                    guard isPlaying, let current else { return }
                    withAnimation { proxy.scrollTo(current, anchor: .center) }
                }
            }
        } else if library.transcribing.contains(item.uuid) {
            ProgressView("Transcribing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Transcript", systemImage: "text.bubble")
            } description: {
                Text(library.transcriptionErrors[item.uuid] ?? "What’s said can be turned into text, on this device, to read along and search.")
            } actions: {
                Button("Transcribe") { Task { await library.transcribe(item) } }
            }
        }
    }

    private func load() {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        Task {
            duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { now in
            MainActor.assumeIsolated {
                if !isScrubbing { time = now.seconds }
                if isPlaying, player.rate == 0, let end = player.currentItem?.duration.seconds, now.seconds >= end - 0.3 {
                    isPlaying = false
                }
            }
        }
    }

    private func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - Email

/// An email: who it's from and to, when, the message, and its attachments.
struct EmailView: View {
    @Environment(Library.self) private var library
    let item: Item
    let url: URL
    @State private var message: MIMEMessage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let message {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(message)
                        Divider()
                        if let text = message.textBody, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if let html = message.htmlBody {
                            // As Markdown: no scripts, and no pictures phoning home.
                            MarkdownView(text: HTMLMarkdown.convert(html))
                                .textSelection(.enabled)
                        }
                        if !message.attachments.isEmpty {
                            Divider()
                            attachments(message)
                        }
                    }
                    .padding()
                    .frame(maxWidth: 760, alignment: .leading)
                }
            } else if loaded {
                ContentUnavailableView("Can’t Read This Message", systemImage: "envelope.badge.shield.half.filled")
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let url = url
            message = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url)).flatMap(MIMEMessage.init)
            }.value
            loaded = true
        }
    }

    private func header(_ message: MIMEMessage) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            row("From", message.from)
            row("To", message.to)
            if !message.cc.isEmpty { row("Cc", message.cc) }
            if let date = message.date {
                GridRow {
                    Text("Date").foregroundStyle(.secondary)
                    Text(date.formatted(date: .complete, time: .shortened))
                }
            }
            GridRow {
                Text("Subject").foregroundStyle(.secondary)
                Text(message.subject).bold()
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ addresses: [MIMEMessage.Address]) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(addresses.map { $0.name.isEmpty ? $0.email : "\($0.name) <\($0.email)>" }.joined(separator: ", "))
        }
    }

    private func attachments(_ message: MIMEMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attachments").font(.headline)
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                HStack {
                    Image(systemName: "paperclip")
                    Text(attachment.fileName)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                        .foregroundStyle(.secondary)
                    Spacer()
                    #if os(macOS)
                    Button("Open") { open(attachment) }
                    #endif
                    Button("Add to Stash") { library.saveAttachment(attachment, of: item) }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    #if os(macOS)
    private func open(_ attachment: MIMEMessage.Attachment) {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(ExportNaming.safe(attachment.fileName))
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? attachment.data.write(to: file)) != nil else { return }
        NSWorkspace.shared.open(file)
    }
    #endif
}

// MARK: - Windows and tabs (Mac)

#if os(macOS)
struct WindowItemKey: FocusedValueKey {
    typealias Value = Item
}

extension FocusedValues {
    /// The item an item window shows, for the menus to act on.
    var windowItem: Item? {
        get { self[WindowItemKey.self] }
        set { self[WindowItemKey.self] = newValue }
    }
}


/// Puts a window opened with *Open in New Tab* in as a tab of the window
/// it was opened from.
struct WindowTabber: NSViewRepresentable {
    /// The window *Open in New Tab* was chosen in, until the new one appears.
    @MainActor static weak var tabTarget: NSWindow?

    func makeNSView(context: Context) -> TabberView { TabberView() }
    func updateNSView(_ view: TabberView, context: Context) {}

    final class TabberView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let target = WindowTabber.tabTarget, target !== window else { return }
            WindowTabber.tabTarget = nil
            DispatchQueue.main.async {
                target.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

extension OpenWindowAction {
    /// Opens an item in a window of its own, or as a tab of the frontmost window.
    @MainActor
    func item(_ item: Item, asTab: Bool) {
        WindowTabber.tabTarget = asTab ? NSApp.keyWindow : nil
        self(id: "item", value: item.uuid)
    }
}
#endif

/// An item in a window of its own: on a Mac, or beside another on an iPad.
struct ItemWindow: View {
    @Environment(Library.self) private var library
    let id: UUID?

    var body: some View {
        if let id, let item = library.items(withIDs: [id]).first, library.isAlive(item) {
            NavigationStack {
                ItemDetailView(item: item)
            }
            .navigationTitle(item.displayTitle)
            #if os(macOS)
            .focusedSceneValue(\.windowItem, item)
            .background(WindowTabber())
            #endif
        } else {
            ContentUnavailableView("Item Not Found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been deleted."))
        }
    }
}

#if os(iOS)
extension OpenWindowAction {
    /// Opens an item in a window of its own, beside the others.
    @MainActor
    func item(_ item: Item) {
        self(id: "item", value: item.uuid)
    }
}
#endif
