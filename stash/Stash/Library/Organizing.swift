import Foundation
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// Keeping things in order: favourites first, copies of items and
/// categories, colours and hand-set order in the sidebar, notes made from
/// other things, and bookmarks brought in from a browser.
extension Library {
    // MARK: - Favourites first

    static var favoritesFirst: Bool {
        get { UserDefaults.standard.bool(forKey: "favoritesFirst") }
        set { UserDefaults.standard.set(newValue, forKey: "favoritesFirst") }
    }

    /// Favourites to the top, keeping the order otherwise.
    func favoritesToTop(_ items: [Item]) -> [Item] {
        items.filter(\.isFavorite) + items.filter { !$0.isFavorite }
    }

    // MARK: - Duplicating

    /// A copy of each item beside it: its text, tags, category, pictures,
    /// file and saved page. Locked items are left out.
    @discardableResult
    func duplicate(_ items: [Item], into category: ItemCategory?? = nil) -> [Item] {
        var copies: [Item] = []
        for original in items where !original.isTrashed && !original.isLocked {
            let copy = Item(kind: original.kind, title: original.displayTitle + (category == nil ? " copy" : ""))
            copy.body = original.body
            copy.summary = original.summary
            copy.urlString = original.urlString
            copy.extractedText = original.extractedText
            copy.articleData = original.articleData
            copy.thumbnailData = original.thumbnailData
            copy.contentTypeIdentifier = original.contentTypeIdentifier
            copy.contentHash = original.contentHash
            copy.labelRaw = original.labelRaw
            copy.rating = original.rating
            copy.customFields = original.customFields
            copy.isTemplate = original.isTemplate
            context.insert(copy)
            copy.category = category ?? original.category
            copy.tags = original.tags
            if original.kind == .document, let source = localFile(for: original) {
                copy.storedFilePath = try? files.importFile(at: source, for: copy.uuid)
                copy.fileData = syncableContents(of: copy)
            }
            if let page = localPageCopy(for: original), let data = try? Data(contentsOf: page) {
                let path = "\(copy.uuid.uuidString)/Page.webarchive"
                if (try? files.write(data, to: path)) != nil {
                    copy.archivePath = path
                    copy.archivedAt = original.archivedAt
                    copy.archiveData = original.archiveData
                }
            }
            for attachment in original.attachments ?? [] {
                guard let data = attachment.data else { continue }
                let picture = NoteAttachment(fileName: attachment.fileName, data: data)
                picture.recognizedText = attachment.recognizedText
                context.insert(picture)
                picture.item = copy
                try? files.write(data, to: "\(copy.uuid.uuidString)/Attachments/\(attachment.fileName)")
            }
            reindex(copy)
            copies.append(copy)
        }
        save()
        revision += 1
        if category == nil, let last = copies.last { selection = last }
        return copies
    }

    /// A copy of a category, the ones inside it, and what's in them.
    @discardableResult
    func duplicate(_ category: ItemCategory, into parent: ItemCategory? = nil, isTop: Bool = true) -> ItemCategory? {
        guard let copy = newCategory(named: category.name + (isTop ? " copy" : ""), in: isTop ? category.parent : parent) else { return nil }
        copy.colorRaw = category.colorRaw
        copy.order = category.order
        let inside = ((try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.trashedAt == nil }))) ?? [])
            .filter { $0.category == category }
        duplicate(inside, into: .some(copy))
        for child in category.subcategories ?? [] { duplicate(child, into: copy, isTop: false) }
        save()
        return copy
    }

    func duplicate(_ filter: SmartFilter) {
        if let copy = newSmartFilter(named: filter.name + " copy", query: filter.query) {
            copy.order = filter.order
            save()
            sidebar = .smartFilter(copy)
        }
    }

    // MARK: - Order and colour in the sidebar

    func setColor(_ label: ItemLabel, of category: ItemCategory) {
        category.colorRaw = label.rawValue
        save()
    }

    /// Moves a category up or down among its siblings.
    func move(_ category: ItemCategory, by step: Int) {
        let siblings: [ItemCategory]
        if let parent = category.parent {
            siblings = (parent.children ?? []).sorted(by: ItemCategory.inOrder)
        } else {
            siblings = ((try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.parent == nil }))) ?? [])
                .sorted(by: ItemCategory.inOrder)
        }
        guard let index = siblings.firstIndex(of: category) else { return }
        var reordered = siblings
        let target = min(max(index + step, 0), siblings.count - 1)
        reordered.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        for (order, sibling) in reordered.enumerated() { sibling.order = order }
        save()
    }

    func smartFiltersInOrder() -> [SmartFilter] {
        ((try? context.fetch(FetchDescriptor<SmartFilter>())) ?? []).sorted {
            $0.order != $1.order ? $0.order < $1.order : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func moveSmartFilters(from offsets: IndexSet, to destination: Int) {
        var filters = smartFiltersInOrder()
        filters.move(fromOffsets: offsets, toOffset: destination)
        for (order, filter) in filters.enumerated() { filter.order = order }
        save()
    }

    // MARK: - Into notes

    /// Whether an item can be made into a note: a link, an email, or a
    /// text, Markdown, rich-text or web-page document.
    static func canMakeNote(from item: Item) -> Bool {
        guard !item.isLocked, !item.isTrashed else { return false }
        switch item.kind {
        case .note: return false
        case .link: return true
        case .document:
            guard let type = item.contentType else { return false }
            return [UTType.emailMessage, .plainText, .rtf, .html, .rtfd].contains { type.conforms(to: $0) }
                || ["md", "markdown"].contains(type.preferredFilenameExtension ?? "")
        }
    }

    /// Notes made from items, beside them and linked from them; the items stay.
    func makeNotes(from items: [Item]) {
        var made: [Item] = []
        for item in items where Self.canMakeNote(from: item) {
            guard let text = noteText(of: item) else { continue }
            let note = Item(kind: .note, title: item.displayTitle)
            note.body = text
            context.insert(note)
            note.category = item.category
            note.tags = item.tags
            link(note, to: item)
            reindex(note)
            made.append(note)
        }
        save()
        revision += 1
        if let last = made.last { selection = last }
    }

    private func noteText(of item: Item) -> String? {
        if item.kind == .link {
            var parts: [String] = []
            if let url = item.urlString { parts.append("Source: [\(WebAddress.displayHost(of: item.url ?? URL(string: "x:")!))](\(url))") }
            if let article = item.article { parts.append(HTMLMarkdown.convert(article.html)) } else if !item.summary.isEmpty { parts.append(item.summary) }
            if !item.body.isEmpty { parts.append("## Notes\n\n" + item.body) }
            return parts.joined(separator: "\n\n")
        }
        guard let url = localFile(for: item), let type = item.contentType, let data = try? Data(contentsOf: url) else { return nil }
        if type.conforms(to: .emailMessage), let message = MIMEMessage(data) {
            let from = message.from.map(\.display).joined(separator: ", ")
            let date = message.date.map { $0.formatted(date: .long, time: .shortened) } ?? ""
            return "**From:** \(from)  \n**Date:** \(date)\n\n" + message.plainText
        }
        if type.conforms(to: .html) {
            return HTMLMarkdown.convert(String(decoding: data, as: UTF8.self))
        }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) {
            let attributed = try? NSAttributedString(data: data, options: [:], documentAttributes: nil)
            return attributed?.string
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Bookmarks

    /// A browser's exported bookmarks file: each bookmark a link, dated when
    /// it was bookmarked, tagged as it was, filed in a category for its
    /// folder under "Bookmarks". Pages already here are skipped; the rest
    /// are fetched one at a time afterwards.
    func importBookmarks(_ url: URL) async -> ImportSummary {
        var summary = ImportSummary()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            summary.failed.append(url.lastPathComponent)
            return summary
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let bookmarks = await Task.detached(priority: .userInitiated) { BookmarksFile.parse(html) }.value
        guard let root = importCategory(named: "Bookmarks", in: nil) else { return summary }
        summary.categoryName = root.path
        var added: [Item] = []
        for (number, bookmark) in bookmarks.enumerated() {
            let address = bookmark.url.absoluteString
            var existing = FetchDescriptor<Item>(predicate: #Predicate { $0.urlString == address })
            existing.fetchLimit = 1
            if ((try? context.fetchCount(existing)) ?? 0) > 0 { continue }
            let item = Item(kind: .link, title: bookmark.title)
            item.urlString = address
            if let added = bookmark.added {
                item.createdAt = added
                item.modifiedAt = added
            }
            context.insert(item)
            item.category = bookmark.folders.reduce(root) { parent, name in importCategory(named: name, in: parent) ?? parent }
            if !bookmark.tags.isEmpty { addTags(from: bookmark.tags.joined(separator: ","), to: item) }
            if let date = bookmark.added { item.modifiedAt = date }
            reindex(item)
            added.append(item)
            if number % 100 == 99 { save(); await Task.yield() }
        }
        summary.links = added.count
        save()
        revision += 1
        sidebar = .category(root)
        Task {
            for item in added where isAlive(item) { await refreshPage(of: item) }
        }
        return summary
    }
}

// MARK: - PDF pages

extension Library {
    /// Whether a PDF's pages can be moved and deleted: one Stash keeps itself,
    /// not locked, not in an indexed folder.
    static func canEditPages(of item: Item) -> Bool {
        item.isPDF && item.indexedFolder == nil && !item.isLocked && item.storedFilePath != nil
    }

    /// Puts a PDF's pages in a new order (`order[i]` is the page that goes
    /// i-th; pages left out are deleted), keeping the original to revert
    /// to, and moving each highlight with its page.
    func arrangePages(of item: Item, order: [Int]) {
        guard Self.canEditPages(of: item), !order.isEmpty, let url = localFile(for: item),
              let document = PDFDocument(url: url) else { return }
        let pages = order.compactMap { document.page(at: $0) }
        guard pages.count == order.count else { return }
        keepOriginal(of: item)
        // The same pages, rearranged in place, so the outline keeps pointing at them.
        while document.pageCount > 0 { document.removePage(at: document.pageCount - 1) }
        for (index, page) in pages.enumerated() { document.insert(page, at: index) }
        guard document.write(to: url) else {
            importError = "The PDF couldn’t be saved."
            return
        }
        let newIndex = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for highlight in item.highlights ?? [] {
            guard case .pdf(let parts)? = highlight.anchor else { continue }
            let moved = parts.compactMap { part in newIndex[part.page].map { HighlightAnchor.PDFPageRects(page: $0, rects: part.rects) } }
            if moved.isEmpty {
                delete(highlight)
                continue
            }
            highlight.anchorJSON = HighlightAnchor.pdf(moved).json
            highlight.position = Double(moved[0].page) + highlight.position.truncatingRemainder(dividingBy: 1)
        }
        if item.readingPosition.hasPrefix("pdf|"), let page = Int(item.readingPosition.dropFirst(4)) {
            item.readingPosition = "pdf|\(newIndex[page] ?? 0)"
        }
        save()
        Task { await fileDidChange(item) }
    }
}

extension Library {
    /// Every category, parents before the ones inside them.
    func allCategories() -> [ItemCategory] {
        let all = (try? context.fetch(FetchDescriptor<ItemCategory>())) ?? []
        return all.filter { $0.parent == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .flatMap(\.flattened)
    }

    func allTagNames() -> [String] {
        ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).map(\.name).sorted()
    }
}
