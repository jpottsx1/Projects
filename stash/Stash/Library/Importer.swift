import Foundation
import SwiftData
import UniformTypeIdentifiers
import StashCore

/// What an import brought in, to say afterwards.
struct ImportSummary {
    var notes = 0
    var documents = 0
    var emails = 0
    var links = 0
    var feeds = 0
    /// Files that couldn't be read, by name.
    var failed: [String] = []
    var categoryName: String?

    var message: String {
        var parts: [String] = []
        if notes > 0 { parts.append(notes == 1 ? "1 note" : "\(notes) notes") }
        if documents > 0 { parts.append(documents == 1 ? "1 document" : "\(documents) documents") }
        if emails > 0 { parts.append(emails == 1 ? "1 email" : "\(emails) emails") }
        if links > 0 { parts.append(links == 1 ? "1 link" : "\(links) links") }
        if feeds > 0 { parts.append(feeds == 1 ? "1 feed" : "\(feeds) feeds") }
        var text = parts.isEmpty ? "Nothing was imported." : "Imported " + parts.joined(separator: " and ")
        if !parts.isEmpty, let categoryName { text += " into “\(categoryName)”" }
        if !parts.isEmpty { text += "." }
        if !failed.isEmpty {
            let names = failed.prefix(5).joined(separator: ", ") + (failed.count > 5 ? " and \(failed.count - 5) more" : "")
            text += "\n\nCouldn’t read: \(names)."
        }
        return text
    }
}

/// Bringing in notes written elsewhere: Evernote exports, and folders of
/// Markdown, text or HTML files (as Obsidian, Bear and Apple Notes
/// exporters make), with their pictures, tags and dates. Each export or
/// folder gets a category, and each folder inside it one inside that.
extension Library {
    // MARK: - Evernote

    func importEvernote(_ urls: [URL]) async -> ImportSummary {
        var summary = ImportSummary()
        var lastCategory: ItemCategory?
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let notes = await Task.detached(priority: .userInitiated, operation: { ENEX.parse(data) }).value else {
                summary.failed.append(url.lastPathComponent)
                continue
            }
            // An export is one notebook, named for it.
            let name = url.deletingPathExtension().lastPathComponent
            let category = importCategory(named: name, in: nil)
            summary.categoryName = urls.count == 1 ? category?.path : nil
            lastCategory = category
            await importEvernoteNotes(notes, into: category, summary: &summary)
        }
        finishImport(showing: lastCategory)
        return summary
    }

    private func importEvernoteNotes(_ notes: [ENEX.Note], into category: ItemCategory?, summary: inout ImportSummary) async {
        var documents: [Item] = []
        for (number, note) in notes.enumerated() {
            let item = Item(kind: .note, title: note.title.isEmpty ? "Untitled" : note.title)
            context.insert(item)
            item.body = ENEX.markdown(of: note) { resource in
                if resource.isPicture {
                    let ext = (resource.suggestedName as NSString).pathExtension
                    return addPicture(resource.data, fileExtension: ext.isEmpty ? "png" : ext, to: item)
                }
                // Other attachments become documents of their own, linked from the note.
                guard let document = addDocument(data: resource.data, named: resource.suggestedName, in: category) else {
                    return nil
                }
                documents.append(document)
                link(item, to: document)
                return "[[\(document.title)]]"
            }
            finishImported(item, tags: note.tags, category: category,
                           created: note.created, modified: note.updated ?? note.created)
            summary.notes += 1
            if number % 25 == 24 { save(); await Task.yield() }
        }
        summary.documents += documents.count
        save()
        readImportedDocuments(documents)
    }

    // MARK: - Folders

    /// A folder of notes: Markdown and text files and HTML pages become
    /// notes, Evernote exports are read too, and other files come in as
    /// documents -- except the pictures the notes show, which go in them.
    func importNotes(from folder: URL) async -> ImportSummary {
        var summary = ImportSummary()
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let files = await Task.detached(priority: .userInitiated) { Self.files(in: folder) }.value
        let root = importCategory(named: folder.lastPathComponent, in: nil)
        summary.categoryName = root?.path
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let byName = Dictionary(files.map { ($0.path.lowercased().components(separatedBy: "/").last ?? "", $0) },
                                uniquingKeysWith: { first, _ in first })
        var used: Set<String> = []
        var documents: [Item] = []

        func url(of file: FolderIndex.File) -> URL { base.appendingPathComponent(file.path) }
        func category(for path: String) -> ItemCategory? {
            FolderIndex.folders(of: path).reduce(root) { parent, name in importCategory(named: name, in: parent) ?? parent }
        }
        /// A picture a note shows, by its path from the note.
        func picture(_ reference: String, from notePath: String, for item: Item) -> String? {
            let folderPath = (notePath as NSString).deletingLastPathComponent
            let joined = ((folderPath as NSString).appendingPathComponent(reference) as NSString).standardizingPath
            let file = files.first { $0.path == joined } ?? byName[(reference as NSString).lastPathComponent.lowercased()]
            guard let file, UTType(filenameExtension: (file.path as NSString).pathExtension)?.conforms(to: .image) == true,
                  let data = try? Data(contentsOf: url(of: file)) else { return nil }
            used.insert(file.path)
            return addPicture(data, fileExtension: (file.path as NSString).pathExtension.lowercased(), to: item)
        }

        for (number, file) in files.enumerated() {
            let ext = (file.path as NSString).pathExtension.lowercased()
            let name = (file.path as NSString).lastPathComponent
            let fileURL = url(of: file)
            let dates = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            if ext == "enex" {
                used.insert(file.path)
                guard let data = try? Data(contentsOf: fileURL), let notes = ENEX.parse(data) else {
                    summary.failed.append(name)
                    continue
                }
                let notebook = importCategory(named: (name as NSString).deletingPathExtension, in: category(for: file.path))
                await importEvernoteNotes(notes, into: notebook, summary: &summary)
            } else if MarkdownImport.isTextBundleExtra(file.path) {
                used.insert(file.path)
            } else if MarkdownImport.markdownExtensions.contains(ext) || MarkdownImport.htmlExtensions.contains(ext) {
                used.insert(file.path)
                let bundle = MarkdownImport.textBundle(file.path)
                guard let text = Self.readText(fileURL) else {
                    summary.failed.append(name)
                    continue
                }
                let item = Item(kind: .note, title: "")
                context.insert(item)
                let note: MarkdownImport.Note
                if MarkdownImport.htmlExtensions.contains(ext) {
                    note = MarkdownImport.note(fromHTML: text, fileName: name) { image in
                        guard let source = image.attributes["src"] else { return nil }
                        if source.hasPrefix("http://") || source.hasPrefix("https://") { return HTMLMarkdown.defaultPicture(image) }
                        return picture(source.removingPercentEncoding ?? source, from: file.path, for: item)
                    }
                } else {
                    // Bear and Ulysses export TextBundles: the note is the bundle's text.
                    var read = MarkdownImport.note(fromMarkdown: text, fileName: bundle.map { $0.name + ".md" } ?? name)
                    read.body = MarkdownImport.replacingLocalPictures(in: read.body) { picture($0, from: file.path, for: item) }
                    note = read
                }
                item.title = note.title
                item.body = note.body
                finishImported(item, tags: note.tags, category: category(for: bundle.map { $0.folder.isEmpty ? "x" : $0.folder + "/x" } ?? file.path),
                               created: note.created ?? dates?.creationDate,
                               modified: note.modified ?? dates?.contentModificationDate)
                summary.notes += 1
            }
            if number % 25 == 24 { save(); await Task.yield() }
        }
        // Whatever no note took in comes in as a document.
        for file in files where !used.contains(file.path) {
            guard let document = addDocument(at: url(of: file), in: category(for: file.path)) else {
                summary.failed.append((file.path as NSString).lastPathComponent)
                continue
            }
            documents.append(document)
        }
        summary.documents += documents.count
        save()
        readImportedDocuments(documents)
        finishImport(showing: root)
        return summary
    }

    /// UTF-8, or failing that the older encodings text files were saved in.
    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .macOSRoman)
    }

    // MARK: - Helpers

    /// A category to import into: the one already there by that name, or a new one.
    func importCategory(named name: String, in parent: ItemCategory?) -> ItemCategory? {
        let siblings: [ItemCategory]
        if let parent {
            siblings = parent.children ?? []
        } else {
            siblings = (try? context.fetch(FetchDescriptor<ItemCategory>(predicate: #Predicate { $0.parent == nil }))) ?? []
        }
        if let existing = siblings.filter({ $0.name == name }).min(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            return existing
        }
        return newCategory(named: name, in: parent)
    }

    /// Tags, category and dates, set last so nothing on the way moves the dates on.
    private func finishImported(_ item: Item, tags: [String], category: ItemCategory?, created: Date?, modified: Date?) {
        if !tags.isEmpty { addTags(from: tags.joined(separator: ","), to: item) }
        item.category = category
        item.inInbox = false
        item.isUnread = false
        if let created { item.createdAt = created }
        item.modifiedAt = modified ?? created ?? item.modifiedAt
        reindex(item)
    }

    private func addDocument(at url: URL, in category: ItemCategory?) -> Item? {
        let item = Item(kind: .document, title: url.deletingPathExtension().lastPathComponent)
        guard let path = try? files.importFile(at: url, for: item.uuid) else { return nil }
        item.storedFilePath = path
        item.contentTypeIdentifier = UTType(filenameExtension: url.pathExtension)?.identifier
        item.fileData = syncableContents(of: item)
        if let dates = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            item.createdAt = dates.creationDate ?? item.createdAt
            item.modifiedAt = dates.contentModificationDate ?? item.modifiedAt
        }
        context.insert(item)
        item.category = category
        reindex(item)
        return item
    }

    func addDocument(data: Data, named name: String, in category: ItemCategory?) -> Item? {
        let item = Item(kind: .document, title: (name as NSString).deletingPathExtension)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let path = "\(item.uuid.uuidString)/\(safe)"
        guard (try? files.write(data, to: path)) != nil else { return nil }
        item.storedFilePath = path
        item.contentTypeIdentifier = UTType(filenameExtension: (safe as NSString).pathExtension)?.identifier
        item.fileData = data.count <= Self.largestSyncedFile ? data : nil
        context.insert(item)
        item.category = category
        reindex(item)
        return item
    }

    /// Hashes, thumbnails and text for imported documents, one at a time.
    private func readImportedDocuments(_ documents: [Item]) {
        guard !documents.isEmpty else { return }
        Task {
            for item in documents where isAlive(item) {
                await fillContentHash(of: item)
                await fillThumbnail(of: item)
                await extractText(from: item)
            }
        }
    }

    private func finishImport(showing category: ItemCategory?) {
        save()
        revision += 1
        sidebar = category.map { .category($0) } ?? .all
    }
}
