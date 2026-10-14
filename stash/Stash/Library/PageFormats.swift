import Foundation
import StashCore
import SwiftUI
import UniformTypeIdentifiers

/// DEVONthink's clip formats: a link's page kept as a PDF (as it looked), a
/// Markdown note (its article), or a web archive document, beside the link
/// and linked from it.
extension Library {
    @discardableResult
    func savePage(_ page: Item, as format: PageFormat) async -> Item? {
        guard page.kind == .link, isAlive(page), !page.isLocked else { return nil }
        let made: Item?
        switch format {
        case .link:
            return nil
        case .pdf:
            guard let file = await ItemPrinter().pdf(of: page, in: self, asPage: true),
                  let data = try? Data(contentsOf: file) else {
                importError = "“\(page.displayTitle)” couldn’t be saved as a PDF."
                return nil
            }
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            made = addDocument(data: data, named: FinderSnapshot.fileName(page.displayTitle, ext: "pdf"), in: page.category)
        case .markdown:
            let note = Item(kind: .note, title: page.displayTitle)
            note.body = Self.markdown(of: page)
            context.insert(note)
            note.category = page.category
            note.tags = page.tags
            reindex(note)
            made = note
        case .webArchive:
            guard let copy = localPageCopy(for: page), let data = try? Data(contentsOf: copy) else {
                importError = "“\(page.displayTitle)” has no saved copy of its page yet. Try Refresh first."
                return nil
            }
            made = addDocument(data: data, named: FinderSnapshot.fileName(page.displayTitle, ext: "webarchive"), in: page.category)
        }
        guard let made, isAlive(page) else { return nil }
        made.sourceAddress = page.urlString
        if made.kind == .document { made.tags = page.tags }
        link(page, to: made)
        save()
        runSearch()
        if made.kind == .document {
            await fillContentHash(of: made)
            await fillThumbnail(of: made)
            await extractText(from: made)
        }
        return made
    }

    /// From the Add Link sheet: the link, then once its page is in, the copy asked for.
    func addLink(_ url: URL, savingAs format: PageFormat) {
        let item = addLink(url)
        guard format != .link else { return }
        Task {
            // addLink is already fetching the page; wait for its copy.
            for _ in 0..<60 where item.archivePath == nil && isAlive(item) {
                try? await Task.sleep(for: .seconds(1))
            }
            if let made = await savePage(item, as: format) { selection = made }
        }
    }
}

/// *Save Page As* on links.
struct PageFormatMenu: View {
    @Environment(Library.self) private var library
    let items: [Item]

    var body: some View {
        let links = items.filter { $0.kind == .link && !$0.isLocked }
        if !links.isEmpty {
            Menu("Save Page As") {
                ForEach(PageFormat.allCases.filter { $0 != .link }) { format in
                    Button(format.name) {
                        Task {
                            var last: Item?
                            for link in links { last = await library.savePage(link, as: format) ?? last }
                            if let last { library.selection = last }
                        }
                    }
                }
            }
        }
    }
}
