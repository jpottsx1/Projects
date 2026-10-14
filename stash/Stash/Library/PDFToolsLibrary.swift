import CoreGraphics
import CoreText
import Foundation
import PDFKit
import SwiftUI
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Merging, splitting and making PDFs, and DEVONthink's Imprinter.
extension Library {
    static func isPicture(_ item: Item) -> Bool {
        item.kind == .document && !item.isSealed && item.contentType?.conforms(to: .image) == true
    }

    /// Several PDFs as one, in title order, filed where the first is and linked to them.
    @discardableResult
    func mergePDFs(_ items: [Item]) -> Item? {
        let pdfs = items.filter(\.isPDF).sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        guard pdfs.count > 1 else { return nil }
        let merged = PDFDocument()
        for pdf in pdfs {
            guard let url = localFile(for: pdf), let document = PDFDocument(url: url) else {
                importError = "“\(pdf.displayTitle)” couldn’t be read, so the PDFs weren’t merged."
                return nil
            }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        return addMade(merged, named: "\(pdfs[0].displayTitle) and \(pdfs.count - 1) more", from: pdfs)
    }

    /// One PDF per range of pages, beside the original and linked from it.
    @discardableResult
    func splitPDF(_ item: Item, into ranges: [ClosedRange<Int>]) -> [Item] {
        guard let url = localFile(for: item), let document = PDFDocument(url: url) else {
            importError = "“\(item.displayTitle)” couldn’t be read."
            return []
        }
        var made: [Item] = []
        for range in ranges {
            let part = PDFDocument()
            for number in range {
                if let page = document.page(at: number - 1)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) }
            }
            if let piece = addMade(part, named: PageRanges.name(item.displayTitle, range), from: [item], select: false) {
                made.append(piece)
            }
        }
        if let first = made.first { selection = first }
        return made
    }

    /// Pictures as the pages of one PDF, in title order.
    @discardableResult
    func makePDF(fromPictures items: [Item]) -> Item? {
        let pictures = items.filter(Self.isPicture)
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        let document = PDFDocument()
        for picture in pictures {
            guard let url = localFile(for: picture) else { continue }
            #if os(macOS)
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { continue }
            #else
            guard let image = UIImage(contentsOfFile: url.path), let page = PDFPage(image: image) else { continue }
            #endif
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0 else {
            importError = "None of the pictures could be read."
            return nil
        }
        let name = pictures.count == 1 ? pictures[0].displayTitle : "\(pictures[0].displayTitle) and \(pictures.count - 1) more"
        return addMade(document, named: name, from: pictures)
    }

    private func addMade(_ document: PDFDocument, named name: String, from sources: [Item], select: Bool = true) -> Item? {
        guard let data = document.dataRepresentation(),
              let item = addDocument(data: data, named: FinderSnapshot.fileName(name, ext: "pdf"), in: sources.first?.category) else {
            importError = "The PDF couldn’t be made."
            return nil
        }
        for source in sources { link(item, to: source) }
        save()
        runSearch()
        if select { selection = item }
        Task {
            await fillContentHash(of: item)
            await fillThumbnail(of: item)
            await extractText(from: item)
        }
        return item
    }

    // MARK: - Imprinter

    /// Stamps the text on every page of each PDF, in place. The file as
    /// first imported is kept, for *Revert to Original*.
    func imprint(_ items: [Item], with imprint: Imprint) {
        let color = Self.cgColor(imprint.color, opacity: imprint.opacity)
        var failed: [String] = []
        for item in items where item.isPDF && Self.canMarkUp(item) {
            guard let path = item.storedFilePath, let url = localFile(for: item),
                  let data = Self.imprinted(url, imprint: imprint, title: item.displayTitle, color: color) else {
                failed.append(item.displayTitle)
                continue
            }
            keepOriginal(of: item)
            do {
                try files.write(data, to: path)
                Task { await fileDidChange(item) }
            } catch {
                failed.append(item.displayTitle)
            }
        }
        if !failed.isEmpty { importError = "Couldn’t imprint " + failed.map { "“\($0)”" }.joined(separator: ", ") + "." }
    }

    private static func cgColor(_ label: Int, opacity: Double) -> CGColor {
        guard label != 0, let itemLabel = ItemLabel(rawValue: label) else {
            return CGColor(gray: 0, alpha: opacity)
        }
        return itemLabel.color.resolve(in: EnvironmentValues()).cgColor.copy(alpha: opacity) ?? CGColor(gray: 0, alpha: opacity)
    }

    /// The PDF drawn again page by page, with the text on top.
    static func imprinted(_ url: URL, imprint: Imprint, title: String, color: CGColor) -> Data? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        let font = CTFontCreateWithName("Helvetica" as CFString, imprint.fontSize, nil)
        let now = Date.now
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            page.draw(with: .mediaBox, to: context)
            if !(imprint.skipsFirstPage && index == 0) {
                let text = imprint.text(page: index + 1, of: document.pageCount, title: title, date: now)
                let attributed = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                let origin = imprint.origin(textWidth: bounds.width, textHeight: bounds.height,
                                            pageWidth: box.width, pageHeight: box.height)
                context.saveGState()
                context.textPosition = CGPoint(x: box.minX + origin.x - bounds.minX, y: box.minY + origin.y - bounds.minY)
                CTLineDraw(line, context)
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
