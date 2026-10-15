import Foundation
import PDFKit
import SwiftData
import StashCore

/// References for citing what's saved, and a document gathering highlights
/// from several items with their references.
extension Library {
    func reference(of item: Item) -> Reference {
        Reference(json: item.referenceJSON)
    }

    /// What's known about it, filled in where the item itself knows (its
    /// title, address, site, when it was saved).
    func citableReference(of item: Item) -> Reference {
        var known = Reference()
        known.title = item.displayTitle
        known.url = item.urlString ?? item.sourceAddress ?? ""
        if let host = item.url?.host ?? item.sourceAddress.flatMap(URL.init(string:))?.host {
            known.siteName = host.replacingOccurrences(of: "www.", with: "")
        }
        known.accessed = CustomField.storedDate(item.createdAt)
        return reference(of: item).merging(known)
    }

    func setReference(_ reference: Reference, of item: Item) {
        item.referenceJSON = reference.json
        reindex(item)
        save()
    }

    /// Fills in what the item's reference doesn't have yet.
    func fillReference(of item: Item, from found: Reference) {
        var found = found
        if found.accessed.isEmpty { found.accessed = CustomField.storedDate(item.createdAt) }
        let merged = reference(of: item).merging(found)
        if merged.json != item.referenceJSON { item.referenceJSON = merged.json }
    }

    /// A PDF's own properties: title, author, subject, keywords, when it was made.
    nonisolated static func pdfReference(at url: URL) -> Reference {
        var reference = Reference()
        guard let attributes = PDFDocument(url: url)?.documentAttributes else { return reference }
        reference.title = (attributes[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
            reference.authors = author.components(separatedBy: CharacterSet(charactersIn: ";&")).flatMap { $0.components(separatedBy: " and ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        reference.description = (attributes[PDFDocumentAttribute.subjectAttribute] as? String) ?? ""
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            reference.keywords = keywords
        } else if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? String {
            reference.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let made = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
            reference.published = CustomField.storedDate(made)
        }
        reference.type = "pdf"
        return reference
    }

    /// Who wrote it and where it's from, for search.
    static func referenceText(_ item: Item) -> String {
        guard !item.referenceJSON.isEmpty else { return "" }
        let reference = Reference(json: item.referenceJSON)
        return ([reference.siteName, reference.publisher, reference.journal, reference.doi] + reference.authors + reference.keywords)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Highlights document

    /// Items a note links to, by `[[link]]` or by hand, in the order first linked.
    func linkedItems(from note: Item) -> [Item] {
        var seen: Set<UUID> = [note.uuid]
        let byTitle = WikiLinks.titles(in: note.body).compactMap(item(titled:))
        return (byTitle + (note.linksTo ?? [])).filter { !$0.isTrashed && seen.insert($0.uuid).inserted }
    }

    /// The items' highlights as one Markdown note, each source under its
    /// title and footnoted to its reference, the references at the end.
    @discardableResult
    func makeHighlightsDocument(from items: [Item], titled title: String, style: Reference.Style) -> Item? {
        let sources = items.filter { !$0.isLocked && !($0.highlights ?? []).isEmpty }.map { item in
            HighlightDigest.Source(
                title: item.displayTitle, reference: citableReference(of: item),
                link: StashURL.itemLink(item.uuid).absoluteString,
                highlights: item.sortedHighlights.map { highlight in
                    var page: Int?
                    if case .pdf(let rects)? = highlight.anchor, let first = rects.first { page = first.page + 1 }
                    return HighlightDigest.Highlight(text: highlight.text, note: highlight.note, page: page)
                })
        }
        guard !sources.isEmpty else {
            importError = "None of these have highlights to gather."
            return nil
        }
        let date = Date.now.formatted(date: .long, time: .omitted)
        let note = newNote(titled: title, text: HighlightDigest.markdown(title: title, sources: sources, style: style, date: date))
        for item in items where !(item.highlights ?? []).isEmpty { link(note, to: item) }
        save()
        return note
    }
}
