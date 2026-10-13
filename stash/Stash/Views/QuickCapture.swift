import SwiftUI
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
/// The menu bar window: jot a note, or save the web address on the
/// clipboard, without going to Stash's window.
struct QuickCaptureView: View {
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow
    @State private var title = ""
    @State private var text = ""
    @State private var saved: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Save Note") { saveNote() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if let saved {
                    Label(saved, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
            Divider()
            Button {
                saveClipboardLink()
            } label: {
                Label(clipboardLink.map { "Save \(WebAddress.displayHost(of: $0))" } ?? "No Web Address on the Clipboard",
                      systemImage: "link.badge.plus")
            }
            .buttonStyle(.borderless)
            .disabled(clipboardLink == nil)
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Stash", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            Text("Saved here goes to the Inbox.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private var clipboardLink: URL? {
        let pasteboard = NSPasteboard.general
        if let url = pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL, !url.isFileURL {
            return WebAddress.url(from: url.absoluteString)
        }
        return pasteboard.string(forType: .string).flatMap(WebAddress.url(from:))
    }

    private func saveNote() {
        library.captureNote(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
        title = ""
        text = ""
        confirm("Note saved")
    }

    private func saveClipboardLink() {
        guard let url = clipboardLink else { return }
        library.captureLink(url)
        confirm("Link saved")
    }

    private func confirm(_ message: String) {
        saved = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            saved = nil
        }
    }
}

/// Stash › Settings.
struct SettingsView: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("dailyNoteFormat") private var dailyFormat = ""

    var body: some View {
        Form {
            Toggle("Show Stash in the menu bar", isOn: $showMenuBarExtra)
            Text("Jot a note or save the web address on the clipboard from anywhere. What you save there goes to the Inbox.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Section("Daily Notes") {
                DailyEventsToggle()
                TextField("Title format", text: $dailyFormat, prompt: Text(NoteTemplate.dailyTitleFormat))
                Text("Today: \(NoteTemplate.format(.now, dailyFormat.isEmpty ? NoteTemplate.dailyTitleFormat : dailyFormat, NoteTemplate.Values()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Feeds") {
                FeedIntervalPicker()
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
#else
/// Home Screen quick actions: touch and hold Stash's icon.
enum QuickActions {
    static let newNote = "com.jpottsx1.stash.new-note"
    static let scan = "com.jpottsx1.stash.scan"
    static let pasteLink = "com.jpottsx1.stash.paste-link"

    /// An action chosen as the app was launched, done once the window is up.
    @MainActor static var pending: String?

    @MainActor
    static func install() {
        var items = [
            UIApplicationShortcutItem(type: newNote, localizedTitle: "New Note", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil")),
            UIApplicationShortcutItem(type: pasteLink, localizedTitle: "Save Copied Link", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "link.badge.plus")),
        ]
        if DocumentScanner.isAvailable {
            items.insert(UIApplicationShortcutItem(type: scan, localizedTitle: "Scan Document", localizedSubtitle: nil,
                                                   icon: UIApplicationShortcutIcon(systemImageName: "doc.viewfinder")),
                         at: 1)
        }
        UIApplication.shared.shortcutItems = items
    }

    @MainActor
    static func perform(_ type: String) {
        let library = StashStore.shared.library
        switch type {
        case newNote:
            library.newNote()
        case scan:
            library.isScanning = true
        case pasteLink:
            let pasteboard = UIPasteboard.general
            if let url = (pasteboard.url.flatMap { WebAddress.url(from: $0.absoluteString) })
                ?? pasteboard.string.flatMap(WebAddress.url(from:)) {
                library.show(library.captureLink(url))
            } else {
                library.importError = "There’s no web address on the clipboard. Copy one, then try again."
            }
        default:
            break
        }
    }

    @MainActor
    static func performPending() {
        guard let type = pending else { return }
        pending = nil
        perform(type)
    }
}

final class StashAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { QuickActions.install() }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Launched by a quick action: do it once the window is up.
        if let type = options.shortcutItem?.type {
            MainActor.assumeIsolated { QuickActions.pending = type }
        }
        // SwiftUI's own name for the scene, so an item window opens as one.
        let configuration = UISceneConfiguration(name: session.configuration.name, sessionRole: session.role)
        configuration.delegateClass = StashSceneDelegate.self
        return configuration
    }
}

/// Quick actions chosen while Stash is already running.
final class StashSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { QuickActions.perform(shortcutItem.type) }
        completionHandler(true)
    }
}
#endif
