#if os(macOS)
import AppKit
import CloudKit
import StashCore
import UniformTypeIdentifiers

/// Stash in every app's Services menu (and on its shortcut, Cmd-Shift-K
/// unless changed in Keyboard settings): Save to Stash takes the selected
/// text, web address or files; Add to Today's Note adds the selected text
/// to the day's note. Both go to the open library.
final class StashServices: NSObject {
    static let shared = StashServices()

    @objc func saveToStash(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        MainActor.assumeIsolated {
            let library = StashStore.shared.library
            if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !files.isEmpty {
                library.importFiles(files)
                return
            }
            if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
               let web = WebAddress.url(from: url.absoluteString) {
                library.captureLink(web)
                return
            }
            guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                error.pointee = "There’s nothing selected that Stash can save."
                return
            }
            // A selection that's just a web address is saved as a link.
            if !text.contains(where: \.isWhitespace), let web = WebAddress.url(from: text) {
                library.captureLink(web)
                return
            }
            let firstLine = text.prefix { $0 != "\n" }
            let title = firstLine.count <= 60 ? String(firstLine) : String(firstLine.prefix(57)) + "…"
            library.captureNote(title: title, text: text)
        }
    }

    @objc func addToTodaysNote(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        MainActor.assumeIsolated {
            guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                error.pointee = "Select some text to add to today’s note."
                return
            }
            StashStore.shared.library.appendToToday(text)
        }
    }
}

/// Offers the services as Stash starts.
final class StashMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = StashServices.shared
        NSUpdateDynamicServices()
    }

    /// An invitation to a category shared through iCloud.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in await Sharing.shared?.accept(metadata) }
    }
}
#endif
