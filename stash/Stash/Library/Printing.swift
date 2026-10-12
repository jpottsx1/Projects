import CoreTransferable
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Printing an item, or saving it as a PDF.
///
/// Notes, articles and saved pages are laid out as HTML -- title, tags,
/// the text, then notes and highlights -- in a web view nobody sees, and
/// printed from there; PDFs and pictures are printed as they are.
@MainActor
final class ItemPrinter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loading: CheckedContinuation<Bool, Never>?

    // MARK: - What's printed

    private enum Content {
        case file(URL)
        case html(String, baseURL: URL?)
        case archive(Data, baseURL: URL?)
    }

    private static func content(for item: Item, in library: Library) -> Content? {
        if item.kind == .document, Library.canMarkUp(item), let file = library.localFile(for: item) {
            return .file(file)
        }
        if item.kind == .link, item.article == nil, let copy = library.localPageCopy(for: item),
           let data = try? Data(contentsOf: copy) {
            return .archive(data, baseURL: item.url)
        }
        return .html(page(for: item, text: library.openSeals[item.uuid]?.body) { library.pictureURL($0, in: item) },
                     baseURL: item.url)
    }

    /// The item as a printable page.
    /// `text` stands in for the item's own when it's encrypted.
    static func page(for item: Item, text: String? = nil, pictureURL: (String) -> URL? = { _ in nil }) -> String {
        let itemText = text ?? item.body
        // Stored pictures go in as data, since the page is loaded from a string.
        let picture: (String) -> String? = { source in
            guard let url = pictureURL(source) else { return nil }
            guard url.isFileURL else { return url.absoluteString }
            guard let data = try? Data(contentsOf: url) else { return nil }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            return "data:\(type);base64," + data.base64EncodedString()
        }
        let escape = MarkdownHTML.escape
        var about: [String] = []
        if let url = item.urlString { about.append("<a href=\"\(escape(url))\">\(escape(url))</a>") }
        if let category = item.category { about.append(escape(category.path)) }
        let tags = item.sortedTags.map { "#" + $0.name }.joined(separator: " ")
        if !tags.isEmpty { about.append(escape(tags)) }
        about.append(item.modifiedAt.formatted(date: .long, time: .omitted))

        var body = ""
        switch item.kind {
        case .note:
            body = MarkdownHTML.render(itemText, picture: picture)
        case .link:
            if let article = item.article {
                body = article.html
            } else if !item.summary.isEmpty {
                body = "<p>\(escape(item.summary))</p>"
            }
            if !itemText.isEmpty { body += "<h2>Notes</h2>" + MarkdownHTML.render(itemText) }
        case .document:
            if !itemText.isEmpty { body = MarkdownHTML.render(itemText) }
        }
        let highlights = item.sortedHighlights
        if !highlights.isEmpty {
            body += "<h2>Highlights</h2>"
            for highlight in highlights {
                body += "<blockquote>\(escape(highlight.text))</blockquote>"
                if !highlight.note.isEmpty { body += MarkdownHTML.render(highlight.note) }
            }
        }
        return """
            <!doctype html><html><head><meta charset="utf-8"><style>
            body { font: 12pt/1.5 "New York", Georgia, serif; color: #111; margin: 0; }
            h1 { font: bold 20pt -apple-system, sans-serif; margin: 0 0 4pt; }
            h2, h3 { font-family: -apple-system, sans-serif; }
            .about { font: 9pt -apple-system, sans-serif; color: #666; margin-bottom: 18pt; }
            .about span + span::before { content: " · "; }
            img { max-width: 100%; }
            pre, code { font: 10pt ui-monospace, Menlo, monospace; }
            pre { white-space: pre-wrap; background: #f4f4f4; padding: 6pt; }
            table { border-collapse: collapse; margin: 6pt 0; }
            th, td { border: 0.5pt solid #bbb; padding: 3pt 6pt; text-align: left; }
            blockquote { margin: 6pt 0; padding-left: 10pt; border-left: 2pt solid #ccc; color: #444; }
            a { color: #1a5fb4; text-decoration: none; }
            li.task { list-style: none; margin-left: -1.2em; }
            </style></head><body>
            <h1>\(escape(item.displayTitle))</h1>
            <div class="about">\(about.map { "<span>\($0)</span>" }.joined())</div>
            \(body)
            </body></html>
            """
    }

    // MARK: - Loading

    private func load(_ content: Content) async -> WKWebView? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        #if os(iOS)
        // In the window, behind everything, as `PageArchiver` does, so it lays out and loads.
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) {
            view.isUserInteractionEnabled = false
            window.insertSubview(view, at: 0)
        }
        #endif
        let loaded: Bool = await withCheckedContinuation { continuation in
            loading = continuation
            switch content {
            case .html(let html, let base): view.loadHTMLString(html, baseURL: base)
            case .archive(let data, let base):
                view.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8",
                          baseURL: base ?? URL(string: "about:blank")!)
            case .file: loading?.resume(returning: false); loading = nil
            }
        }
        guard loaded else { return nil }
        // Pictures in an article come from the web; give them a moment.
        try? await Task.sleep(for: .seconds(1))
        return view
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume(returning: true)
        loading = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading?.resume(returning: false)
        loading = nil
    }

    private func finish() {
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: - Printing

    func print(_ item: Item, in library: Library) async {
        guard let content = Self.content(for: item, in: library) else { return }
        #if os(iOS)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = item.displayTitle
        info.outputType = .general
        controller.printInfo = info
        if case .file(let url) = content {
            controller.printingItem = url
        } else {
            guard let view = await load(content) else { return }
            controller.printFormatter = view.viewPrintFormatter()
        }
        controller.present(animated: true) { [weak self] _, _, _ in self?.finish() }
        #else
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let operation: NSPrintOperation?
        if case .file(let url) = content {
            operation = Self.document(from: url)?.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true)
        } else {
            guard let view = await load(content) else { return }
            operation = view.printOperation(with: .shared)
            operation?.view?.frame = NSRect(x: 0, y: 0, width: 612, height: 792)
        }
        operation?.jobTitle = item.displayTitle
        operation?.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        finish()
        #endif
    }

    // MARK: - PDF

    /// A PDF of the item in a temporary folder, for saving.
    func pdf(of item: Item, in library: Library) async -> URL? {
        guard let content = Self.content(for: item, in: library) else { return nil }
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ExportNaming.safe(item.displayTitle) + ".pdf")
        defer { finish() }

        if case .file(let file) = content {
            guard let document = Self.document(from: file), document.write(to: url) else { return nil }
            return url
        }
        guard let view = await load(content) else { return nil }
        #if os(iOS)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(view.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        renderer.setValue(paper, forKey: "paperRect")
        renderer.setValue(paper.insetBy(dx: 54, dy: 54), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, [kCGPDFContextTitle as String: item.displayTitle])
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
        #else
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return nil }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = view.printOperation(with: info)
        operation.view?.frame = NSRect(x: 0, y: 0, width: 612, height: 792)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let done = await withCheckedContinuation { continuation in
            let waiter = PrintWaiter(continuation)
            operation.runModal(for: window, delegate: waiter,
                               didRun: #selector(PrintWaiter.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
            objc_setAssociatedObject(operation, "waiter", waiter, .OBJC_ASSOCIATION_RETAIN)
        }
        return done && FileManager.default.fileExists(atPath: url.path) ? url : nil
        #endif
    }

    /// A PDF document from a PDF, or a one-page one from a picture.
    private static func document(from url: URL) -> PDFDocument? {
        if let pdf = PDFDocument(url: url) { return pdf }
        #if os(iOS)
        guard let image = UIImage(contentsOfFile: url.path), let page = PDFPage(image: image) else { return nil }
        #else
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { return nil }
        #endif
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }
}

#if os(macOS)
/// Hears when a print operation run as a sheet has finished.
private final class PrintWaiter: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        continuation?.resume(returning: success)
        continuation = nil
    }
}
#endif
