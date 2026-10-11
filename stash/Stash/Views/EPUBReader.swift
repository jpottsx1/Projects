import SwiftUI
import WebKit
import StashCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reads an EPUB book a chapter at a time, remembering where you got to.
/// Select some text, then Highlight; tap a highlight to write a note on it.
struct EPUBReader: View {
    @Environment(Library.self) private var library
    let item: Item
    let url: URL
    @State private var document: EPUBDocument?
    @State private var failed = false
    @State private var controller = EPUBController()
    @AppStorage("bookZoom") private var zoom = 1.0

    var body: some View {
        Group {
            if let document {
                EPUBWebView(controller: controller)
                    .onAppear { controller.open(document, item: item, library: library, zoom: zoom) }
            } else if failed {
                ContentUnavailableView("Can’t Read This Book", systemImage: "book.closed",
                                       description: Text("The file isn’t an EPUB book Stash understands. Quick Look may still show it."))
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let url = self.url
            let opened = await Task.detached(priority: .userInitiated) { try? EPUBDocument(url: url) }.value
            document = opened
            failed = opened == nil
        }
        .onChange(of: PDFReader.signature(item.sortedHighlights)) {
            controller.showHighlights()
        }
        .onChange(of: library.revealedHighlight) { _, highlight in
            guard let highlight, highlight.item == item else { return }
            controller.reveal(highlight)
            library.revealedHighlight = nil
        }
        .onChange(of: zoom) { controller.setZoom(zoom) }
        .toolbar {
            if let document {
                ToolbarItemGroup {
                    Button {
                        controller.go(by: -1)
                    } label: {
                        Label("Previous Chapter", systemImage: "chevron.left")
                    }
                    .disabled(controller.chapter <= 0)
                    contents(of: document.book)
                    Button {
                        controller.go(by: 1)
                    } label: {
                        Label("Next Chapter", systemImage: "chevron.right")
                    }
                    .disabled(controller.chapter >= document.book.chapters.count - 1)
                }
                ToolbarItem {
                    Menu {
                        Button("Larger Text") { zoom = min(zoom + 0.1, 3) }
                        Button("Smaller Text") { zoom = max(zoom - 0.1, 0.5) }
                        Button("Actual Size") { zoom = 1 }
                    } label: {
                        Label("Text Size", systemImage: "textformat.size")
                    }
                }
                ToolbarItem {
                    HighlightMenu { color, withNote in
                        Task { await highlightSelection(color, withNote: withNote) }
                    }
                }
            }
        }
    }

    private func contents(of book: EPUBBook) -> some View {
        Menu {
            if book.toc.isEmpty {
                ForEach(book.chapters.indices, id: \.self) { index in
                    Button("Chapter \(index + 1)") { controller.open(target: book.chapters[index].path) }
                }
            } else {
                ForEach(Array(book.toc.enumerated()), id: \.offset) { _, entry in
                    Button(String(repeating: "    ", count: min(entry.level, 4)) + entry.title) {
                        controller.open(target: entry.target)
                    }
                }
            }
        } label: {
            Label("Contents", systemImage: "list.bullet")
        }
        .help(book.title ?? "Contents")
    }

    private func highlightSelection(_ color: HighlightColor, withNote: Bool) async {
        guard let passage = await controller.selectedPassage() else { return }
        let highlight = library.addHighlight(to: item, text: passage.text, anchor: passage.anchor,
                                             position: passage.position, color: color)
        if withNote { library.editingHighlight = highlight }
    }
}

/// Runs the book's web view: which chapter is showing, the highlights in
/// it, and where you are.
@MainActor
@Observable
final class EPUBController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let scheme = "stash-book"

    private(set) var chapter = 0
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private var document: EPUBDocument?
    @ObservationIgnored private weak var item: Item?
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var scrollAfterLoad: Double?
    @ObservationIgnored private var revealAfterLoad: UUID?

    struct Passage {
        var text: String
        var anchor: HighlightAnchor
        var position: Double
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(EPUBSchemeHandler(controller: self), forURLScheme: Self.scheme)
        let scripts = configuration.userContentController
        scripts.add(WeakMessageHandler(self), name: "stash")
        scripts.addUserScript(WKUserScript(source: WebHighlights.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    func file(at path: String) throws -> Data {
        guard let document else { throw URLError(.fileDoesNotExist) }
        return try document.data(at: path)
    }

    /// Shows the book, at the chapter and place it was left.
    func open(_ document: EPUBDocument, item: Item, library: Library, zoom: Double) {
        guard self.document !== document else { return }
        self.document = document
        self.item = item
        self.library = library
        setZoom(zoom)
        let saved = item.readingPosition.split(separator: "|", maxSplits: 1)
        if let path = saved.first.map(String.init), let index = document.book.chapterIndex(for: path) {
            scrollAfterLoad = saved.count > 1 ? Double(saved[1]) : nil
            load(index)
        } else {
            load(0)
        }
    }

    func setZoom(_ zoom: Double) {
        webView?.pageZoom = zoom
    }

    func go(by step: Int) {
        guard let count = document?.book.chapters.count else { return }
        load(min(max(chapter + step, 0), count - 1))
    }

    /// A chapter, perhaps with "#section" after it.
    func open(target: String) {
        guard let book = document?.book, let index = book.chapterIndex(for: target) else { return }
        let fragment = target.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init)
        load(index, fragment: fragment)
    }

    private func load(_ index: Int, fragment: String? = nil) {
        guard let book = document?.book, book.chapters.indices.contains(index), let webView else { return }
        chapter = index
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "book"
        components.path = "/" + book.chapters[index].path
        components.fragment = fragment
        if let url = components.url { webView.load(URLRequest(url: url)) }
    }

    var chapterPath: String? {
        document?.book.chapters.indices.contains(chapter) == true ? document?.book.chapters[chapter].path : nil
    }

    // MARK: - Highlights

    /// Draws this chapter's highlights, found again by their words.
    func showHighlights() {
        guard let webView, let path = chapterPath, let item else { return }
        let highlights = item.sortedHighlights.compactMap { highlight -> (Highlight, TextQuote)? in
            guard case .epub(let chapter, let quote)? = highlight.anchor, chapter == path else { return nil }
            return (highlight, quote)
        }
        Task {
            await WebHighlights.show(highlights, in: webView)
            if let reveal = revealAfterLoad {
                revealAfterLoad = nil
                WebHighlights.reveal(reveal, in: webView)
            }
        }
    }

    func reveal(_ highlight: Highlight) {
        guard case .epub(let path, _)? = highlight.anchor, let book = document?.book,
              let index = book.chapterIndex(for: path) else { return }
        if index == chapter {
            if let webView { WebHighlights.reveal(highlight.uuid, in: webView) }
        } else {
            revealAfterLoad = highlight.uuid
            load(index)
        }
    }

    func selectedPassage() async -> Passage? {
        guard let webView, let path = chapterPath, let selected = await WebHighlights.selection(in: webView) else {
            return nil
        }
        return Passage(text: selected.words, anchor: .epub(chapter: path, quote: selected.quote),
                       position: Double(chapter) + selected.fraction)
    }

    // MARK: - Web view

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == Self.scheme {
            // A link to another chapter.
            if navigationAction.navigationType == .linkActivated, let book = document?.book,
               let index = book.chapterIndex(for: String(url.path.dropFirst())) {
                chapter = index
            }
            return .allow
        }
        if navigationAction.navigationType == .linkActivated {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            _ = await UIApplication.shared.open(url)
            #endif
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let fraction = scrollAfterLoad {
            scrollAfterLoad = nil
            webView.evaluateJavaScript("stash.scrollTo(\(fraction))")
        } else {
            savePosition(0)
        }
        showHighlights()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "position":
            savePosition((body["value"] as? NSNumber)?.doubleValue ?? 0)
        case "tap":
            guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            library?.editingHighlight = item?.highlights?.first { $0.uuid == id }
        default:
            break
        }
    }

    private func savePosition(_ fraction: Double) {
        guard let item, let library, let path = chapterPath else { return }
        let position = "\(path)|\((fraction * 1000).rounded() / 1000)"
        if item.readingPosition != position {
            item.readingPosition = position
            library.save()
        }
    }

    /// The book's layout, and reporting how far through a chapter you are.
    /// Highlighting comes from `WebHighlights.script`.
    static let script = #"""
    (function () {
      const style = document.createElement('style');
      style.textContent = `
        :root { color-scheme: light dark; }
        body { max-width: 40em; margin: 0 auto !important; padding: 1.5em 1.5em 4em !important; line-height: 1.6; }
        img, svg, video { max-width: 100%; height: auto; }`;
      (document.head || document.documentElement).appendChild(style);

      window.stash.scrollTo = (fraction) => {
        setTimeout(() => {
          const height = document.documentElement.scrollHeight - window.innerHeight;
          window.scrollTo(0, Math.max(0, fraction * height));
        }, 60);
      };
      let timer;
      window.addEventListener('scroll', () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const height = document.documentElement.scrollHeight - window.innerHeight;
          window.webkit.messageHandlers.stash.postMessage(
            { type: 'position', value: height > 0 ? window.scrollY / height : 0 });
        }, 800);
      });
    })();
    """#
}

/// Serves the book's files to its web view from inside the EPUB.
private final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var controller: EPUBController?

    init(controller: EPUBController) {
        self.controller = controller
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = String(url.path.dropFirst())
        MainActor.assumeIsolated {
            do {
                guard let controller else { throw URLError(.cancelled) }
                let data = try controller.file(at: path)
                let response = URLResponse(url: url, mimeType: EPUBDocument.mimeType(for: path),
                                           expectedContentLength: data.count, textEncodingName: nil)
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            } catch {
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// The content controller holds its handlers strongly; this keeps that
/// from keeping the reader alive.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

#if os(macOS)
struct EPUBWebView: NSViewRepresentable {
    let controller: EPUBController
    func makeNSView(context: Context) -> WKWebView { controller.webView ?? controller.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct EPUBWebView: UIViewRepresentable {
    let controller: EPUBController
    func makeUIView(context: Context) -> WKWebView { controller.webView ?? controller.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
