import Foundation
import SwiftUI
import StashCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Searching the web for a picture: by the address it came from where
/// there is one, otherwise by copying it to paste into the site's page,
/// since the sites can't read files on this device (see `ImageSearch`).
extension Library {
    /// Whether the item is a picture that can be searched for.
    static func canSearchImage(_ item: Item) -> Bool {
        guard !item.isTrashed, !item.isLocked else { return false }
        if item.kind == .link, let address = item.urlString { return ImageSearch.isImageAddress(address) }
        return item.kind == .document && item.contentType?.conforms(to: .image) == true
    }

    /// The web address the picture can be fetched from, if it has one.
    static func imageSearchAddress(for item: Item) -> String? {
        if item.kind == .link, let address = item.urlString, ImageSearch.isImageAddress(address) { return address }
        guard let source = item.sourceAddress, ImageSearch.Engine.googleLens.searchURL(forImageAt: source) != nil else { return nil }
        return source
    }

    func searchImage(_ item: Item, with engine: ImageSearch.Engine) {
        if let address = Self.imageSearchAddress(for: item), let url = engine.searchURL(forImageAt: address) {
            Self.openInBrowser(url)
            return
        }
        guard let file = localFile(for: item), copyImage(at: file) else {
            importError = "“\(item.displayTitle)” couldn’t be read to search for."
            return
        }
        Self.openInBrowser(engine.pasteURL)
        imageSearchNotice = """
            “\(item.displayTitle)” has no web address \(engine.name) can fetch, so it’s been copied. \
            Paste it into the search page (\(Self.pasteShortcut)).
            """
    }

    private func copyImage(at file: URL) -> Bool {
        #if os(macOS)
        guard let image = NSImage(contentsOf: file) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
        #else
        guard let image = UIImage(contentsOfFile: file.path) else { return false }
        UIPasteboard.general.image = image
        return true
        #endif
    }

    private static var pasteShortcut: String {
        #if os(macOS)
        "Cmd-V"
        #else
        "touch and hold, then Paste"
        #endif
    }

    private static func openInBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func setSourceAddress(_ text: String, of item: Item) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        item.sourceAddress = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// A downloaded file's "Where from", as the Finder shows it.
    nonisolated static func whereFrom(_ file: URL) -> String? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size else { return nil }
        return ImageSearch.whereFrom(data)
    }
}

/// *Search Image With* in an item's menus.
struct ImageSearchMenu: View {
    @Environment(Library.self) private var library
    let item: Item

    var body: some View {
        if Library.canSearchImage(item) {
            if item.kind == .link, let url = item.url, ImageSearch.isImageAddress(url.absoluteString) {
                Button("Save Full-Size Image") { Task { await library.saveFullSizeImage(from: url, page: nil, category: item.category) } }
            } else if item.sourceAddress != nil, Library.canMarkUp(item) {
                Button("Get Full-Size Version") {
                    Task {
                        if !(await library.getFullSizeVersion(of: item)) {
                            library.importError = "No bigger version of “\(item.displayTitle)” was found."
                        }
                    }
                }
                .help("Looks for the biggest version of the picture where it came from, and uses it if it's bigger")
            }
            Menu("Search Image With") {
                ForEach(ImageSearch.Engine.allCases) { engine in
                    Button(engine.name) { library.searchImage(item, with: engine) }
                }
                Divider()
                if let address = Library.imageSearchAddress(for: item) {
                    Text("By its address: " + (URL(string: address)?.host ?? address))
                } else {
                    Text("Copied, to paste into the site")
                }
            }
        }
    }
}
